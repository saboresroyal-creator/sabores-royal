// WhatsApp Cloud API (Meta). Variables de entorno en Vercel:
//   WHATSAPP_ACCESS_TOKEN     token permanente del usuario del sistema (también vale WHATSAPP_TOKEN)
//   WHATSAPP_PHONE_NUMBER_ID  id del número (no es el número en sí)

const GRAPH = 'https://graph.facebook.com/v23.0';
const NOT_ALLOWED = 131030; // "Recipient phone number not in allowed list"

const token = () => process.env.WHATSAPP_ACCESS_TOKEN || process.env.WHATSAPP_TOKEN;

async function post(body){
  const res = await fetch(`${GRAPH}/${process.env.WHATSAPP_PHONE_NUMBER_ID}/messages`, {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + token(),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  if(!res.ok){
    const text = await res.text();
    let code;
    try{ code = JSON.parse(text).error.code; }catch{}
    throw Object.assign(new Error('WhatsApp ' + res.status + ': ' + text), { code });
  }
  return res.json();
}

// Números argentinos: WhatsApp los manda con el 9 (549 341 6833210) pero
// Meta a veces los tiene registrados sin el 9 o con el 15 después de la
// característica (54 341 15 6833210) y rechaza el envío con el formato del
// 9. Si pasa, se prueban los otros formatos. La característica puede ser
// de 2, 3 o 4 dígitos (11, 341, 2954...).
function argentineVariants(to){
  const d = String(to).replace(/\D/g, '');
  if(!/^549\d{10}$/.test(d)) return [];
  const rest = d.slice(3);
  return [
    '54' + rest,
    ...[3, 2, 4].map(n => '54' + rest.slice(0, n) + '15' + rest.slice(n)),
  ];
}
const workingRecipient = new Map(); // wa_id -> formato que Meta aceptó

async function sendOne(to, payload){
  const first = workingRecipient.get(to) || to;
  try{
    return await post({ messaging_product: 'whatsapp', to: first, ...payload });
  }catch(e){
    if(e.code !== NOT_ALLOWED) throw e;
    for(const alt of argentineVariants(to).filter(v => v !== first)){
      try{
        const r = await post({ messaging_product: 'whatsapp', to: alt, ...payload });
        workingRecipient.set(to, alt);
        return r;
      }catch(e2){
        if(e2.code !== NOT_ALLOWED) throw e2;
      }
    }
    throw e;
  }
}

// WhatsApp corta los mensajes de texto en 4096 caracteres.
export async function sendText(to, text){
  const chunks = [];
  let rest = String(text || '').trim();
  while(rest.length > 4000){
    let cut = rest.lastIndexOf('\n', 4000);
    if(cut < 2000) cut = 4000;
    chunks.push(rest.slice(0, cut));
    rest = rest.slice(cut).trim();
  }
  if(rest) chunks.push(rest);
  for(const chunk of chunks){
    await sendOne(to, { type: 'text', text: { body: chunk, preview_url: false } });
  }
}

// Tilde azul + "escribiendo..." mientras la IA arma la respuesta.
export async function markReadTyping(messageId){
  try{
    await post({ messaging_product: 'whatsapp', status: 'read', message_id: messageId, typing_indicator: { type: 'text' } });
  }catch(e){ console.warn('markReadTyping:', e.message); }
}
