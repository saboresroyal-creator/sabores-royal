import Anthropic from '@anthropic-ai/sdk';
import { getVercelOidcToken } from '@vercel/functions/oidc';

// Deuda Proveedores (caja-diaria.html): el usuario saca una foto de la
// factura/remito/nota de crédito que le dejó el proveedor y esta función le
// pide a Claude que lea los datos. Devuelve solo los campos del formulario;
// el usuario los revisa antes de guardar — acá no se escribe nada.
// Qué IA usa, en orden: Claude directo (ANTHROPIC_API_KEY), Gemini
// (GEMINI_API_KEY) o Claude a través del AI Gateway de Vercel, que se
// autentica solo con el token OIDC del proyecto (no hace falta copiar claves).

export const config = { maxDuration: 60 };

// Mismo proyecto que el resto de la app. La anon key ya es pública (viaja en
// el cliente); acá solo se usa para validar el PIN de la caja.
const SUPABASE_URL = 'https://topgunweqeztedhhthbl.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRvcGd1bndlcWV6dGVkaGh0aGJsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI3NDczMjgsImV4cCI6MjA5ODMyMzMyOH0.KfZ8f8GlKoQoRxdPk-lrNDSTRcjd21z6d8CgITHf3WU';

const MEDIA_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'application/pdf'];

const COMPROBANTE_SCHEMA = {
  type: 'object',
  properties: {
    legible: { type: 'boolean' },
    tipo: { type: 'string', enum: ['factura', 'remito', 'nc'] },
    numero: { type: 'string' },
    proveedor: { type: 'string' },
    fechaEmision: { type: 'string' },
    fechaVencimiento: { type: 'string' },
    total: { type: 'number' },
    observaciones: { type: 'string' },
  },
  required: ['legible', 'tipo', 'numero', 'proveedor', 'fechaEmision', 'fechaVencimiento', 'total', 'observaciones'],
  additionalProperties: false,
};

const SYSTEM_PROMPT = `Leés comprobantes de proveedores de Sabores Royal, un comercio de Rosario (Argentina), a partir de una foto o un PDF, para cargarlos en su registro de deudas con proveedores.

Sabores Royal es el que COMPRA: el proveedor es quien emite el comprobante (razón social o nombre de fantasía del encabezado), nunca Sabores Royal.

Devolvé:
- legible: false si la imagen no es un comprobante o no se puede leer el total; true si sí.
- tipo: "factura" (Factura A, B, C o similar), "remito" o "nc" (Nota de Crédito).
- numero: el número del comprobante tal como figura, con punto de venta (ej: "0003-00012345"). "" si no aparece.
- proveedor: el nombre del emisor. Si coincide con uno de los proveedores conocidos que te pasan, usá exactamente ese nombre.
- fechaEmision: fecha de emisión en formato AAAA-MM-DD. Las fechas argentinas vienen como DD/MM/AAAA. "" si no aparece.
- fechaVencimiento: la fecha de vencimiento PARA EL PAGO, en AAAA-MM-DD. Ojo: el "Vto. CAE" o "Fecha de Vto. de CAE" de AFIP NO es el vencimiento del pago; ignoralo. Si no hay vencimiento de pago, "".
- total: el importe TOTAL final a pagar del comprobante (con IVA y percepciones), como número con "." decimal, sin "$" ni puntos de miles. 0 si no se lee.
- observaciones: una frase corta solo si hay algo dudoso que el usuario deba revisar (ej: "el total está borroso", "hay dos totales"); si no, "".

No inventes datos: si un campo no se ve, dejalo vacío.`;

// Deja la respuesta de la IA (Claude o Gemini) con los tipos que espera el formulario.
function normalizar(c) {
  c = c || {};
  const fecha = (s) => (typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : '');
  const total = typeof c.total === 'number' ? c.total : parseFloat(String(c.total || '').replace(',', '.'));
  return {
    legible: c.legible === true || c.legible === 'true',
    tipo: ['factura', 'remito', 'nc'].includes(c.tipo) ? c.tipo : 'factura',
    numero: String(c.numero || '').trim(),
    proveedor: String(c.proveedor || '').trim(),
    fechaEmision: fecha(c.fechaEmision),
    fechaVencimiento: fecha(c.fechaVencimiento),
    total: total > 0 ? Math.round(total * 100) / 100 : 0,
    observaciones: String(c.observaciones || '').trim(),
  };
}

// Gemini por REST. El formato de la respuesta se pide en el texto (y en
// JSON con responseMimeType) para no depender de los parámetros de esquema,
// que cambiaron de nombre entre versiones de la API.
const FORMATO_JSON = `\n\nRespondé SOLO con un objeto JSON con estas claves exactas: legible (boolean), tipo ("factura" | "remito" | "nc"), numero (string), proveedor (string), fechaEmision (string AAAA-MM-DD o ""), fechaVencimiento (string AAAA-MM-DD o ""), total (number), observaciones (string).`;

// Modelos a probar en orden: en el plan gratuito a veces uno está saturado
// ("high demand") o sin cupo, y otro responde bien.
const GEMINI_MODELOS = ['gemini-flash-latest', 'gemini-3.8-flash', 'gemini-3.7-flash', 'gemini-3.6-flash', 'gemini-3.5-flash', 'gemini-flash-lite-latest'];

async function leerConGemini(data, mediaType, pedido) {
  const modelos = process.env.GEMINI_MODEL ? [process.env.GEMINI_MODEL, ...GEMINI_MODELOS] : GEMINI_MODELOS;
  // Vercel corta la función a los 60 s: cada modelo tiene un tope de espera
  // y se deja margen para responder.
  const limite = Date.now() + 50000;
  let ultimoError;
  for (const modelo of [...new Set(modelos)]) {
    const resta = limite - Date.now();
    if (resta < 5000) break;
    try {
      return await geminiUnModelo(modelo, data, mediaType, pedido, Math.min(22000, resta));
    } catch (e) {
      ultimoError = e;
      // Saturado, sin cupo o inexistente: probar el siguiente. Otro error: cortar.
      if (![404, 429, 500, 503].includes(e.status)) throw e;
    }
  }
  throw ultimoError;
}

async function geminiUnModelo(modelo, data, mediaType, pedido, espera) {
  const hasta = Date.now() + espera;
  const llamar = (generationConfig) => fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(modelo)}:generateContent`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': process.env.GEMINI_API_KEY },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: SYSTEM_PROMPT + FORMATO_JSON }] },
        contents: [{ role: 'user', parts: [{ inline_data: { mime_type: mediaType, data } }, { text: pedido }] }],
        ...(generationConfig ? { generationConfig } : {}),
      }),
      signal: AbortSignal.timeout(Math.max(1000, hasta - Date.now())),
    }
  );
  let r;
  try {
    r = await llamar({ responseMimeType: 'application/json', temperature: 0 });
    if (r.status === 400) r = await llamar(null); // por si esta versión no acepta esa config
  } catch (e) {
    // Tardó demasiado (modelo saturado): se trata igual que un 503 para probar el siguiente.
    throw Object.assign(new Error('El modelo tardó demasiado en responder'), { status: 503 });
  }
  const body = await r.json().catch(() => ({}));
  if (!r.ok) {
    const err = new Error((body.error && body.error.message) || ('HTTP ' + r.status));
    err.status = r.status;
    throw err;
  }
  const texto = (((body.candidates || [])[0] || {}).content || {}).parts?.map((p) => p.text || '').join('') || '';
  const json = texto.slice(texto.indexOf('{'), texto.lastIndexOf('}') + 1);
  if (!json) throw new Error('Respuesta vacía de Gemini');
  return JSON.parse(json);
}

// Claude a través del AI Gateway de Vercel (API compatible con la de Anthropic).
async function leerConGateway(data, mediaType, pedido) {
  const token = process.env.AI_GATEWAY_API_KEY || await getVercelOidcToken();
  const client = new Anthropic({ apiKey: token, baseURL: 'https://ai-gateway.vercel.sh' });
  const archivo = mediaType === 'application/pdf'
    ? { type: 'document', source: { type: 'base64', media_type: mediaType, data } }
    : { type: 'image', source: { type: 'base64', media_type: mediaType, data } };
  const response = await client.messages.create({
    model: process.env.AI_GATEWAY_MODEL || 'anthropic/claude-opus-5.5',
    max_tokens: 4000,
    system: SYSTEM_PROMPT + FORMATO_JSON,
    messages: [{ role: 'user', content: [archivo, { type: 'text', text: pedido }] }],
  });
  if (response.stop_reason === 'refusal') throw Object.assign(new Error('No se pudo leer este comprobante'), { status: 422 });
  const texto = response.content.filter((b) => b.type === 'text').map((b) => b.text).join('');
  const json = texto.slice(texto.indexOf('{'), texto.lastIndexOf('}') + 1);
  if (!json) throw new Error('Respuesta vacía de la IA');
  return JSON.parse(json);
}

async function pinValido(pin) {
  if (!pin || typeof pin !== 'string') return false;
  const res = await fetch(SUPABASE_URL + '/rest/v1/rpc/get_caja_diaria', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + SUPABASE_ANON_KEY },
    body: JSON.stringify({ p_pin: pin }),
  });
  return res.ok;
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { pin, data, mediaType, proveedores } = req.body || {};
  try {
    if (!(await pinValido(pin))) return res.status(401).json({ error: 'PIN de la caja inválido' });
  } catch (e) {
    return res.status(401).json({ error: 'No se pudo verificar el PIN' });
  }
  if (!data || typeof data !== 'string') return res.status(400).json({ error: 'Falta la foto' });
  if (!MEDIA_TYPES.includes(mediaType)) return res.status(400).json({ error: 'Formato no soportado (usá foto o PDF)' });
  const conocidos = Array.isArray(proveedores)
    ? proveedores.filter((p) => typeof p === 'string' && p.trim()).slice(0, 300)
    : [];
  const hoy = new Date().toLocaleDateString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' });
  const pedido = `Hoy es ${hoy}.
Proveedores conocidos: ${conocidos.length ? conocidos.join(', ') : '(ninguno todavía)'}\n\nLeé este comprobante.`;

  // Sin clave de Anthropic: Gemini si hay clave; si no, el AI Gateway de Vercel.
  if (!process.env.ANTHROPIC_API_KEY && !process.env.GEMINI_API_KEY) {
    try {
      return res.json(normalizar(await leerConGateway(data, mediaType, pedido)));
    } catch (error) {
      console.error('factura-foto gateway error:', error);
      const msg = String(error.message || '');
      if (error.status === 401 || /oidc|token/i.test(msg)) return res.status(503).json({ error: 'La lectura de fotos todavía no está activada (falta activar el AI Gateway en Vercel)' });
      if (error.status === 403) return res.status(503).json({ error: 'El AI Gateway de Vercel pide una tarjeta o saldo cargado para usarlo: ' + msg });
      if (error.status === 429) return res.status(429).json({ error: 'Demasiadas consultas, probá en un minuto' });
      return res.status(502).json({ error: 'Error de la IA: ' + msg });
    }
  }
  if (!process.env.ANTHROPIC_API_KEY) {
    try {
      return res.json(normalizar(await leerConGemini(data, mediaType, pedido)));
    } catch (error) {
      console.error('factura-foto gemini error:', error);
      return res.status([429, 503].includes(error.status) ? 503 : 502).json({
        error: [429, 503].includes(error.status) ? 'La IA gratuita de Google está saturada en este momento, probá de nuevo en un rato' : 'Error de la IA: ' + error.message,
      });
    }
  }

  const archivo = mediaType === 'application/pdf'
    ? { type: 'document', source: { type: 'base64', media_type: mediaType, data } }
    : { type: 'image', source: { type: 'base64', media_type: mediaType, data } };

  try {
    const anthropic = new Anthropic();
    const response = await anthropic.beta.messages.create({
      model: 'claude-opus-5-5',
      max_tokens: 4000,
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      output_config: {
        effort: 'medium',
        format: { type: 'json_schema', schema: COMPROBANTE_SCHEMA },
      },
      system: SYSTEM_PROMPT,
      messages: [{
        role: 'user',
        content: [
          archivo,
          { type: 'text', text: pedido },
        ],
      }],
    });

    if (response.stop_reason === 'refusal') {
      return res.status(422).json({ error: 'No se pudo leer este comprobante' });
    }
    const textBlock = response.content.find((b) => b.type === 'text');
    if (!textBlock) return res.status(502).json({ error: 'Respuesta vacía del modelo' });

    let c;
    try {
      c = JSON.parse(textBlock.text);
    } catch (e) {
      return res.status(502).json({ error: 'El modelo devolvió un formato inválido' });
    }

    res.json(normalizar(c));
  } catch (error) {
    console.error('factura-foto error:', error);
    if (error instanceof Anthropic.RateLimitError) return res.status(429).json({ error: 'Demasiadas consultas, probá en un minuto' });
    if (error instanceof Anthropic.APIError) return res.status(502).json({ error: 'Error de la IA: ' + error.message });
    res.status(500).json({ error: error.message || 'Error al leer la foto' });
  }
}
