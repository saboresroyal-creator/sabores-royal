import Anthropic from '@anthropic-ai/sdk';

// Deuda Proveedores (caja-diaria.html): el usuario saca una foto de la
// factura/remito/nota de crédito que le dejó el proveedor y esta función le
// pide a Claude que lea los datos. Devuelve solo los campos del formulario;
// el usuario los revisa antes de guardar — acá no se escribe nada.

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
  if (!process.env.ANTHROPIC_API_KEY) {
    return res.status(500).json({ error: 'El servidor no tiene configurada ANTHROPIC_API_KEY' });
  }

  const conocidos = Array.isArray(proveedores)
    ? proveedores.filter((p) => typeof p === 'string' && p.trim()).slice(0, 300)
    : [];
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
          { type: 'text', text: `Proveedores conocidos: ${conocidos.length ? conocidos.join(', ') : '(ninguno todavía)'}\n\nLeé este comprobante.` },
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

    const fecha = (s) => (typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : '');
    res.json({
      legible: !!c.legible,
      tipo: ['factura', 'remito', 'nc'].includes(c.tipo) ? c.tipo : 'factura',
      numero: String(c.numero || '').trim(),
      proveedor: String(c.proveedor || '').trim(),
      fechaEmision: fecha(c.fechaEmision),
      fechaVencimiento: fecha(c.fechaVencimiento),
      total: typeof c.total === 'number' && c.total > 0 ? Math.round(c.total * 100) / 100 : 0,
      observaciones: String(c.observaciones || '').trim(),
    });
  } catch (error) {
    console.error('factura-foto error:', error);
    if (error instanceof Anthropic.RateLimitError) return res.status(429).json({ error: 'Demasiadas consultas, probá en un minuto' });
    if (error instanceof Anthropic.APIError) return res.status(502).json({ error: 'Error de la IA: ' + error.message });
    res.status(500).json({ error: error.message || 'Error al leer la foto' });
  }
}
