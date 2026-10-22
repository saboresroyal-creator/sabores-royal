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

// Modo detalle (Ingreso de mercadería en el admin): además de la cabecera,
// los renglones de productos para sumar stock y actualizar costos.
const DETALLE_EXTRA = `

Además leé el DETALLE de productos del comprobante. Devolvé también:
- letra: la letra del comprobante "A", "B", "C" o "" si no figura (en la A los precios suelen ser SIN IVA; en B y C, con IVA).
- items: un renglón por cada producto facturado, en el orden en que aparecen, con:
  - descripcion: el texto del producto tal como figura.
  - codigo: el código del artículo o de barras si aparece; si no, "".
  - cantidad: la cantidad facturada en ese renglón (número, tal como figura, sea por unidad o por bulto/caja).
  - unidadesPorBulto: si el renglón se factura por bulto/caja/display y la descripción o una columna indica cuántas unidades trae (ej: "x12", "12x500g", "CAJA 24 UN"), ese número; si se factura por unidad o no se sabe, 1.
  - precioUnitario: el precio unitario del renglón tal como figura (por la misma unidad que la cantidad), número con "." decimal.
  - subtotal: el importe total del renglón ya con descuentos/bonificaciones del renglón, número; 0 si no figura.
No incluyas renglones de impuestos, percepciones, fletes ni subtotales generales. Si no hay detalle de productos, items: [].`;
const FORMATO_DETALLE = `, letra (string), items (array de objetos con descripcion (string), codigo (string), cantidad (number), unidadesPorBulto (number), precioUnitario (number), subtotal (number)).`;
const DETALLE_SCHEMA = {
  ...COMPROBANTE_SCHEMA,
  properties: {
    ...COMPROBANTE_SCHEMA.properties,
    letra: { type: 'string' },
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          descripcion: { type: 'string' }, codigo: { type: 'string' }, cantidad: { type: 'number' },
          unidadesPorBulto: { type: 'number' }, precioUnitario: { type: 'number' }, subtotal: { type: 'number' },
        },
        required: ['descripcion', 'codigo', 'cantidad', 'unidadesPorBulto', 'precioUnitario', 'subtotal'],
        additionalProperties: false,
      },
    },
  },
  required: [...COMPROBANTE_SCHEMA.required, 'letra', 'items'],
};
const num = (v) => { const n = typeof v === 'number' ? v : parseFloat(String(v || '').replace(/\./g, '').replace(',', '.')); return Number.isFinite(n) ? n : 0; };
function normalizarDetalle(c) {
  const base = normalizar(c);
  const items = (Array.isArray(c && c.items) ? c.items : []).map((it) => ({
    descripcion: String(it.descripcion || '').trim(),
    codigo: String(it.codigo || '').trim(),
    cantidad: typeof it.cantidad === 'number' ? it.cantidad : num(it.cantidad),
    unidadesPorBulto: Math.max(1, Math.round(typeof it.unidadesPorBulto === 'number' ? it.unidadesPorBulto : num(it.unidadesPorBulto)) || 1),
    precioUnitario: typeof it.precioUnitario === 'number' ? it.precioUnitario : num(it.precioUnitario),
    subtotal: typeof it.subtotal === 'number' ? it.subtotal : num(it.subtotal),
  })).filter((it) => it.descripcion && it.cantidad > 0).slice(0, 300);
  const letra = String((c && c.letra) || '').trim().toUpperCase();
  return { ...base, letra: ['A', 'B', 'C'].includes(letra) ? letra : '', items };
}

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

// En el plan gratuito a veces un modelo está saturado ("high demand") o sin
// cupo, y otro responde bien. Cada modelo tiene su propio cupo, así que
// conviene tener varios. Los alias "-latest" siempre existen; además se le
// pide a Google la lista real de modelos (los nombres cambian con cada
// versión) y se suman todos los "flash" que lean imágenes.
const GEMINI_ALIAS = ['gemini-flash-latest', 'gemini-flash-lite-latest'];
let _modelosCache = null, _modelosCacheHasta = 0;
// Modelo sin cupo (429) o inexistente (404): no se vuelve a probar por un rato.
const _enPausa = new Map();

async function modelosGemini() {
  if (_modelosCache && Date.now() < _modelosCacheHasta) return _modelosCache;
  let descubiertos = [];
  try {
    const r = await fetch('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200', {
      headers: { 'x-goog-api-key': process.env.GEMINI_API_KEY },
      signal: AbortSignal.timeout(4000),
    });
    const body = await r.json();
    descubiertos = (body.models || [])
      .filter((m) => (m.supportedGenerationMethods || []).includes('generateContent'))
      .map((m) => String(m.name || '').replace(/^models\//, ''))
      .filter((n) => /^gemini-[\d.]+-flash/.test(n) && !/image|tts|audio|live|embedding/.test(n))
      // Versión más nueva primero; los "lite" (más flojos para leer) al final.
      .sort((a, b) => (/lite/.test(a) - /lite/.test(b)) || parseFloat(b.slice(7)) - parseFloat(a.slice(7)));
  } catch (e) { /* sin lista: quedan los alias */ }
  const pref = process.env.GEMINI_MODEL ? [process.env.GEMINI_MODEL] : [];
  const lista = [...new Set([...pref, GEMINI_ALIAS[0], ...descubiertos.filter((n) => !/lite/.test(n)), GEMINI_ALIAS[1], ...descubiertos.filter((n) => /lite/.test(n))])];
  _modelosCache = lista;
  _modelosCacheHasta = Date.now() + 3600000;
  return lista;
}

// Prueba de a dos modelos a la vez y se queda con el primero que responde:
// si uno está saturado no hay que esperarlo para pasar al siguiente.
async function leerConGemini(data, mediaType, pedido, sistema) {
  const todos = await modelosGemini();
  const ahora = Date.now();
  const modelos = todos.filter((m) => !(_enPausa.get(m) > ahora));
  if (!modelos.length) modelos.push(...todos);
  // Vercel corta la función a los 60 s: se deja margen para responder.
  const limite = Date.now() + 50000;
  const PARALELO = 2;
  return new Promise((resolve, reject) => {
    let siguiente = 0, enCurso = 0, terminado = false, ultimoError = null;
    const lanzar = () => {
      while (!terminado && enCurso < PARALELO && siguiente < modelos.length) {
        const resta = limite - Date.now();
        if (resta < 5000) break;
        const modelo = modelos[siguiente++];
        enCurso++;
        geminiUnModelo(modelo, data, mediaType, pedido, Math.min(25000, resta), sistema)
          .then((r) => { if (!terminado) { terminado = true; resolve(r); } })
          .catch((e) => {
            ultimoError = e;
            if (e.status === 429) _enPausa.set(modelo, Date.now() + 60000);
            if (e.status === 404) _enPausa.set(modelo, Date.now() + 3600000);
            // Saturado, sin cupo o inexistente: probar el siguiente. Otro error: cortar.
            if (![404, 429, 500, 503].includes(e.status) && !terminado) { terminado = true; reject(e); }
          })
          .finally(() => {
            enCurso--;
            lanzar();
            if (!terminado && enCurso === 0) { terminado = true; reject(ultimoError || Object.assign(new Error('Sin modelos disponibles'), { status: 503 })); }
          });
      }
    };
    lanzar();
    if (enCurso === 0 && !terminado) { terminado = true; reject(Object.assign(new Error('Sin tiempo para probar modelos'), { status: 503 })); }
  });
}

async function geminiUnModelo(modelo, data, mediaType, pedido, espera, sistema) {
  const hasta = Date.now() + espera;
  const llamar = (generationConfig) => fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(modelo)}:generateContent`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': process.env.GEMINI_API_KEY },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: sistema }] },
        contents: [{ role: 'user', parts: [{ inline_data: { mime_type: mediaType, data } }, { text: pedido }] }],
        ...(generationConfig ? { generationConfig } : {}),
      }),
      signal: AbortSignal.timeout(Math.max(1000, hasta - Date.now())),
    }
  );
  let r;
  try {
    // Sin "pensar" responde bastante más rápido y para leer un comprobante no hace falta.
    r = await llamar({ responseMimeType: 'application/json', temperature: 0, thinkingConfig: { thinkingBudget: 0 } });
    if (r.status === 400) r = await llamar({ responseMimeType: 'application/json', temperature: 0 });
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
async function leerConGateway(data, mediaType, pedido, sistema) {
  const token = process.env.AI_GATEWAY_API_KEY || await getVercelOidcToken();
  const client = new Anthropic({ apiKey: token, baseURL: 'https://ai-gateway.vercel.sh' });
  const archivo = mediaType === 'application/pdf'
    ? { type: 'document', source: { type: 'base64', media_type: mediaType, data } }
    : { type: 'image', source: { type: 'base64', media_type: mediaType, data } };
  const response = await client.messages.create({
    model: process.env.AI_GATEWAY_MODEL || 'anthropic/claude-opus-5.5',
    max_tokens: 16000,
    system: sistema,
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

// Sesión de admin del panel (Ingreso de mercadería): el token de Supabase
// tiene que pertenecer a un usuario de admin_users.
async function adminValido(token) {
  if (!token || typeof token !== 'string') return false;
  const res = await fetch(SUPABASE_URL + '/rest/v1/rpc/is_admin', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + token },
    body: '{}',
  });
  return res.ok && (await res.json().catch(() => false)) === true;
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { pin, adminToken, data, mediaType, proveedores } = req.body || {};
  const detalle = !!(req.body && req.body.detalle);
  try {
    const ok = adminToken ? await adminValido(adminToken) : await pinValido(pin);
    if (!ok) return res.status(401).json({ error: adminToken ? 'Tu sesión de admin venció: volvé a entrar' : 'PIN de la caja inválido' });
  } catch (e) {
    return res.status(401).json({ error: 'No se pudo verificar el acceso' });
  }
  const sistema = detalle ? SYSTEM_PROMPT + DETALLE_EXTRA + FORMATO_JSON.replace(/\.$/, FORMATO_DETALLE) : SYSTEM_PROMPT + FORMATO_JSON;
  const salida = detalle ? normalizarDetalle : normalizar;
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
      return res.json(salida(await leerConGateway(data, mediaType, pedido, sistema)));
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
      return res.json(salida(await leerConGemini(data, mediaType, pedido, sistema)));
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
      max_tokens: detalle ? 16000 : 4000,
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      output_config: {
        effort: 'medium',
        format: { type: 'json_schema', schema: detalle ? DETALLE_SCHEMA : COMPROBANTE_SCHEMA },
      },
      system: detalle ? SYSTEM_PROMPT + DETALLE_EXTRA : SYSTEM_PROMPT,
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

    res.json(salida(c));
  } catch (error) {
    console.error('factura-foto error:', error);
    if (error instanceof Anthropic.RateLimitError) return res.status(429).json({ error: 'Demasiadas consultas, probá en un minuto' });
    if (error instanceof Anthropic.APIError) return res.status(502).json({ error: 'Error de la IA: ' + error.message });
    res.status(500).json({ error: error.message || 'Error al leer la foto' });
  }
}
