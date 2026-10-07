// Acceso a Supabase para el bot. Usa la service_role key (variable de
// entorno en Vercel, NUNCA en el frontend): el bot necesita leer ventas,
// clientes y sus propias tablas, que con la anon key están cerradas.

const SUPABASE_URL = 'https://topgunweqeztedhhthbl.supabase.co';

function key(){
  const k = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if(!k) throw new Error('Falta SUPABASE_SERVICE_ROLE_KEY en Vercel');
  return k;
}

async function request(path, { method = 'GET', body, prefer } = {}){
  const headers = {
    apikey: key(),
    Authorization: 'Bearer ' + key(),
    'Content-Type': 'application/json',
  };
  if(prefer) headers.Prefer = prefer;
  const res = await fetch(SUPABASE_URL + '/rest/v1' + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if(!res.ok){
    let msg = text;
    try{ msg = JSON.parse(text).message || text; }catch{}
    throw new Error(msg);
  }
  return text ? JSON.parse(text) : null;
}

export const db = {
  get: (path) => request(path),
  insert: (table, row, prefer = 'return=representation') =>
    request('/' + table, { method: 'POST', body: row, prefer }),
  patch: (path, body) => request(path, { method: 'PATCH', body, prefer: 'return=representation' }),
  rpc: (fn, args) => request('/rpc/' + fn, { method: 'POST', body: args }),
};

// Mismo criterio que normalizePhone() del frontend: siempre +549 + número,
// con el 9. Si se pierde el 9 se crean clientes duplicados.
export function normalizePhone(raw){
  let digits = String(raw || '').replace(/\D/g, '');
  if(digits.startsWith('54')) digits = digits.slice(2);
  if(digits.startsWith('9')) digits = digits.slice(1);
  return '+549' + digits;
}

export async function getSetting(key){
  const rows = await db.get('/app_settings?select=setting_value&setting_key=eq.' + encodeURIComponent(key));
  return rows && rows[0] ? rows[0].setting_value : null;
}

export async function setSetting(key, value){
  await request('/app_settings?on_conflict=setting_key', {
    method: 'POST',
    body: { setting_key: key, setting_value: value },
    prefer: 'resolution=merge-duplicates,return=minimal',
  });
}

// Argentina es UTC-3 todo el año (sin horario de verano).
export function todayAR(){
  return new Date(Date.now() - 3 * 3600 * 1000).toISOString().slice(0, 10);
}
export function nowARText(){
  const d = new Date(Date.now() - 3 * 3600 * 1000);
  const dias = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
  return `${dias[d.getUTCDay()]} ${d.toISOString().slice(0, 10)} ${d.toISOString().slice(11, 16)} (hora de Argentina)`;
}
