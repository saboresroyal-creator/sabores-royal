import Anthropic from '@anthropic-ai/sdk';

// Asociación de productos entre proveedores con IA. El matching por texto
// del comparador (cmpProdSimRows en index.html) no puede saber que "Lc" es
// La Campagnola, que "Bom Bob" es Bon o Bon, ni que "Dulce Batata Lc" y
// "NOEL DULCE BATATA" son marcas distintas. El frontend arma, para cada
// producto, hasta 5 candidatos del otro proveedor (búsqueda por texto,
// gratis) y acá la IA solo elige cuál es el mismo producto o ninguno.

export const config = { maxDuration: 60 };

const SUPABASE_URL = 'https://topgunweqeztedhhthbl.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRvcGd1bndlcWV6dGVkaGh0aGJsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI3NDczMjgsImV4cCI6MjA5ODMyMzMyOH0.KfZ8f8GlKoQoRxdPk-lrNDSTRcjd21z6d8CgITHf3WU';

const RESULT_SCHEMA = {
  type: 'object',
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          match: { type: 'integer' },
        },
        required: ['id', 'match'],
        additionalProperties: false,
      },
    },
  },
  required: ['results'],
  additionalProperties: false,
};

const SYSTEM_PROMPT = `Comparás listas de precios de distintos proveedores mayoristas argentinos (golosinas, almacén, bebidas, limpieza) para un comercio que quiere saber quién vende más barato el MISMO producto.

Para cada producto te doy una lista numerada de candidatos de otro proveedor. Devolvé el número del candidato que es exactamente el mismo producto, o -1 si ninguno lo es.

Es el mismo producto solo si coinciden:
- Marca. Ojo con las abreviaturas ("Lc" = La Campagnola, "Bc" = BC, "Arc" = Arcor, "Bom Bob" = Bon o Bon) y con que muchos proveedores omiten la marca del fabricante cuando la lista es de ese mismo fabricante (en la lista de Arcor, "Mogul Moras" es "ARCOR MOGUL MORAS"). Si los dos nombran marcas y son distintas, NO es el mismo producto aunque el resto coincida.
- Variedad / sabor / tipo ("sin azúcar", "light", "sin TACC" con producto equivalente, colores, sabores).
- Tamaño de la unidad (gramos, ml, kg). La cantidad de unidades por bulto PUEDE ser distinta (12x390 y 6x390 son el mismo producto en bultos distintos).

Ante la duda real, devolvé -1: es peor asociar dos productos distintos que dejar uno sin pareja.`;

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

  // items: [{ id, name, provA, provB, cands: [name, ...] }]
  const { items } = req.body || {};
  if (!Array.isArray(items) || !items.length || items.length > 40) {
    return res.status(400).json({ error: 'Mandá entre 1 y 40 productos' });
  }
  if (!process.env.ANTHROPIC_API_KEY) {
    return res.status(500).json({ error: 'El servidor no tiene configurada ANTHROPIC_API_KEY' });
  }

  const text = items.map((it) => {
    const cands = (it.cands || []).slice(0, 8).map((c, i) => `  ${i}. ${String(c).slice(0, 200)}`).join('\n');
    return `[${it.id}] ${String(it.name).slice(0, 200)}  (proveedor ${String(it.provA || '').slice(0, 60)})\nCandidatos de ${String(it.provB || '').slice(0, 60)}:\n${cands}`;
  }).join('\n\n');

  try {
    const anthropic = new Anthropic();
    const response = await anthropic.beta.messages.create({
      model: 'claude-opus-5-5',
      max_tokens: 16000,
      betas: ['server-side-fallback-2026-06-01'],
      fallbacks: [{ model: 'claude-opus-4-8' }],
      output_config: {
        effort: 'low',
        format: { type: 'json_schema', schema: RESULT_SCHEMA },
      },
      system: SYSTEM_PROMPT,
      messages: [{ role: 'user', content: text }],
    });

    if (response.stop_reason === 'refusal') {
      return res.status(422).json({ error: 'El modelo no pudo procesar estos productos' });
    }
    const textBlock = response.content.find((b) => b.type === 'text');
    if (!textBlock) return res.status(502).json({ error: 'Respuesta vacía del modelo' });

    let parsed;
    try {
      parsed = JSON.parse(textBlock.text);
    } catch (e) {
      return res.status(502).json({ error: 'El modelo devolvió un formato inválido' });
    }

    const byId = {};
    items.forEach((it) => { byId[String(it.id)] = (it.cands || []).length; });
    const results = (parsed.results || [])
      .filter((r) => r && byId[String(r.id)] !== undefined)
      .map((r) => ({
        id: String(r.id),
        match: Number.isInteger(r.match) && r.match >= 0 && r.match < byId[String(r.id)] ? r.match : -1,
      }));

    res.json({ results });
  } catch (error) {
    console.error('comparador-match error:', error);
    res.status(500).json({ error: error.message || 'Error al procesar con IA' });
  }
}
