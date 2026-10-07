// WhatsApp Cloud API (Meta). Variables de entorno en Vercel:
//   WHATSAPP_TOKEN            token permanente del usuario del sistema
//   WHATSAPP_PHONE_NUMBER_ID  id del número (no es el número en sí)

const GRAPH = 'https://graph.facebook.com/v23.0';

async function post(body){
  const res = await fetch(`${GRAPH}/${process.env.WHATSAPP_PHONE_NUMBER_ID}/messages`, {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + process.env.WHATSAPP_TOKEN,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  if(!res.ok){
    const text = await res.text();
    throw new Error('WhatsApp ' + res.status + ': ' + text);
  }
  return res.json();
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
    await post({ messaging_product: 'whatsapp', to, type: 'text', text: { body: chunk, preview_url: false } });
  }
}

// Tilde azul + "escribiendo..." mientras Claude piensa la respuesta.
export async function markReadTyping(messageId){
  try{
    await post({ messaging_product: 'whatsapp', status: 'read', message_id: messageId, typing_indicator: { type: 'text' } });
  }catch(e){ console.warn('markReadTyping:', e.message); }
}
