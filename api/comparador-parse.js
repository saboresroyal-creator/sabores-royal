import Anthropic from '@anthropic-ai/sdk';

// El comparador de precios sube listas de proveedores en cualquier formato
// (Excel, PDF, texto pegado a mano) y hasta acá el admin tenía que mapear
// a mano qué columna era el producto, cuál el precio, etc. Esta función le
// pasa el texto crudo a Claude y le pide que devuelva directamente los
// productos ya estructurados — reemplaza el mapeo manual por completo.

// Vercel sube el límite de duración por función con este export; el default
// (10s en el plan Hobby) se queda corto para listas largas.
export const config = { maxDuration: 60 };

// Mismos valores que usa el frontend (public/index.html) — la anon key ya
// es pública (viaja en el cliente), solo la usamos acá para validar la
// sesión del admin que llama a este endpoint, no para escribir nada.
const SUPABASE_URL = 'https://topgunweqeztedhhthbl.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRvcGd1bndlcWV6dGVkaGh0aGJsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI3NDczMjgsImV4cCI6MjA5ODMyMzMyOH0.KfZ8f8GlKoQoRxdPk-lrNDSTRcjd21z6d8CgITHf3WU';

const ITEM_SCHEMA = {
  type: 'object',
  properties: {
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          price: { type: 'number' },
          unit: { type: 'string' },
          unitQty: { type: 'integer' },
          code: { type: 'string' },
        },
        required: ['name', 'price', 'unit', 'unitQty', 'code'],
        additionalProperties: false,
      },
    },
  },
  required: ['items'],
  additionalProperties: false,
};

const SYSTEM_PROMPT = `Sos un asistente que convierte listas de precios de proveedores (golosinas, dietética, almacén) en datos estructurados para un comparador de precios.

El texto de entrada viene de un Excel, PDF o texto pegado a mano — puede venir desprolijo: columnas mezcladas, sin encabezados claros, con títulos de sección, totales, o líneas vacías.

Para cada producto real que encuentres, devolvé:
- name: el nombre/descripción del producto, limpio (sin el precio ni la presentación pegados).
- price: el precio de esa línea tal como figura en la lista, como número (sin "$", sin puntos de miles; usá "." como separador decimal). Si hay dos precios (ej: contado/tarjeta), usá el primero o el de contado.
- unit: la presentación tal como aparece (ej: "caja x24", "bolsa 1kg"). Si no hay, dejalo en "".
- unitQty: cuántas unidades individuales hay en esa presentación (para poder comparar precio por unidad). Inferilo del texto de presentación o del nombre del producto (ej: "x12", "docena" = 12, "display 24u" = 24). Si el producto se vende suelto, o no podés inferirlo, usá 1.
- code: código/SKU del producto si aparece en la lista, si no "".

Ignorá encabezados de columna, títulos de sección, totales, subtotales y líneas sin precio válido. No inventes productos que no estén en el texto.`;

async function requireSuperAdmin(req) {
  const authHeader = req.headers.authorization || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  if (!token) return { ok: false, status: 401, error: 'No autenticado' };

  const userRes = await fetch(SUPABASE_URL + '/auth/v1/user', {
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + token },
  });
  if (!userRes.ok) return { ok: false, status: 401, error: 'Sesión inválida' };
  const user = await userRes.json();

  const adminRes = await fetch(
    SUPABASE_URL + '/rest/v1/admin_users?select=user_id,is_super&user_id=eq.' + encodeURIComponent(user.id),
    { headers: { apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + token } }
  );
  if (!adminRes.ok) return { ok: false, status: 403, error: 'Sin acceso' };
  const rows = await adminRes.json();
  if (!rows.length || !rows[0].is_super) {
    return { ok: false, status: 403, error: 'Esta función es solo para superadmin' };
  }
  return { ok: true };
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Method not allowed' });
  }

  let auth;
  try {
    auth = await requireSuperAdmin(req);
  } catch (e) {
    return res.status(401).json({ error: 'No se pudo verificar la sesión' });
  }
  if (!auth.ok) return res.status(auth.status).json({ error: auth.error });

  const { text, filename } = req.body || {};
  if (!text || typeof text !== 'string' || !text.trim()) {
    return res.status(400).json({ error: 'Falta el texto de la lista' });
  }
  if (!process.env.ANTHROPIC_API_KEY) {
    return res.status(500).json({ error: 'El servidor no tiene configurada ANTHROPIC_API_KEY' });
  }

  const wasTruncated = text.length > 60000;
  const inputText = wasTruncated ? text.slice(0, 60000) : text;

  try {
    const anthropic = new Anthropic();
    const response = await anthropic.messages.create({
      model: 'claude-opus-4-8',
      max_tokens: 8000,
      output_config: {
        effort: 'medium',
        format: { type: 'json_schema', schema: ITEM_SCHEMA },
      },
      system: SYSTEM_PROMPT,
      messages: [
        { role: 'user', content: `Archivo: ${filename || 'sin nombre'}\n\n${inputText}` },
      ],
    });

    if (response.stop_reason === 'refusal') {
      return res.status(422).json({ error: 'El modelo no pudo procesar este archivo' });
    }

    const textBlock = response.content.find((b) => b.type === 'text');
    if (!textBlock) return res.status(502).json({ error: 'Respuesta vacía del modelo' });

    let parsed;
    try {
      parsed = JSON.parse(textBlock.text);
    } catch (e) {
      return res.status(502).json({ error: 'El modelo devolvió un formato inválido' });
    }

    const items = Array.isArray(parsed.items) ? parsed.items : [];
    const cleaned = items
      .filter((it) => it && it.name && typeof it.price === 'number' && it.price > 0)
      .map((it) => ({
        name: String(it.name).trim(),
        price: Number(it.price),
        unit: it.unit ? String(it.unit).trim() : '',
        unitQty: Number.isInteger(it.unitQty) && it.unitQty > 0 ? it.unitQty : 1,
        code: it.code ? String(it.code).trim() : '',
      }));

    res.json({ items: cleaned, truncated: wasTruncated });
  } catch (error) {
    console.error('comparador-parse error:', error);
    res.status(500).json({ error: error.message || 'Error al procesar con IA' });
  }
}
