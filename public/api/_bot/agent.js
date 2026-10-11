// Cerebro del bot: toma los mensajes sin procesar de un teléfono, arma el
// turno para la IA, corre las herramientas y contesta por WhatsApp.
//
// IA: Claude si hay ANTHROPIC_API_KEY cargada; si no, Gemini gratis
// (GEMINI_API_KEY). Las herramientas y las reglas son las mismas en los dos.

import { db, normalizePhone, getSetting, nowARText } from './db.js';
import { sendText } from './wa.js';
import { customerTools } from './tools-clientes.js';
import { ownerTools, executeAction } from './tools-duenio.js';
import { CUSTOMER_PROMPT, OWNER_PROMPT } from './prompts.js';
import { notifyOwner, ownerWaIds } from './notify.js';
import { claudeLLM } from './llm-claude.js';
import { geminiLLM } from './llm-gemini.js';

const SESSION_IDLE_HOURS = 12;   // charla nueva si pasó este tiempo sin mensajes
const SESSION_MAX_MESSAGES = 80; // o si el historial ya es muy largo
const CONFIRM_RE = /^\s*(s[ií]+|dale|ok|okey|confirmo|confirmado|hacelo|de una|va)\b/i;

function pickLLM(){
  if(claudeLLM.available()) return claudeLLM;
  if(geminiLLM.available()) return geminiLLM;
  throw new Error('No hay ninguna IA configurada (falta GEMINI_API_KEY en Vercel)');
}

export function isOwner(phone){
  return ownerWaIds().some(id => normalizePhone(id) === phone);
}

function messageText(m){
  if(m.type === 'text') return m.body;
  if(m.type === 'audio') return '[mandó un audio]';
  if(m.type === 'image') return m.body ? `[mandó una foto con el texto: ${m.body}]` : '[mandó una foto]';
  return m.body || `[mandó un mensaje de tipo ${m.type}]`;
}

// WhatsApp usa *negrita* con un asterisco; los modelos a veces escriben
// markdown (**negrita**, # títulos).
function toWhatsApp(text){
  return String(text || '')
    .replace(/\*\*(.+?)\*\*/g, '*$1*')
    .replace(/^#{1,6}\s+(.+)$/gm, '*$1*')
    .trim();
}

async function buildSessionContext(phone, owner, profileName){
  const info = (await getSetting('bot_info')) || '(sin cargar)';
  if(owner) return `Info del negocio que ven los clientes:\n${info}`;
  const rows = await db.get(`/clients?select=full_name,wholesale,rubro,points,address&phone=eq.${encodeURIComponent(phone)}`);
  const c = rows[0];
  const who = c
    ? `Cliente registrado: ${c.full_name}${c.wholesale ? ` — MAYORISTA${c.rubro ? ' (' + c.rubro + ')' : ''}` : ' — minorista'}${c.address ? `. Dirección guardada: ${c.address}` : ''}${c.points ? `. Puntos: ${c.points}` : ''}.`
    : `Cliente no registrado todavía (nombre de perfil de WhatsApp: ${profileName || 'desconocido'}). Para el sistema es minorista.`;
  return `${who}\nTeléfono: ${phone}\n\nInfo del negocio:\n${info}`;
}

// Procesa todos los mensajes pendientes de un teléfono en un solo turno.
// Devuelve false si no había nada que procesar.
async function processBatch(phone, deadline){
  const inbox = await db.get(`/bot_inbox?select=*&phone=eq.${encodeURIComponent(phone)}&processed_at=is.null&order=received_at.asc&limit=20`);
  if(!inbox.length) return false;
  const markDone = () => db.patch(`/bot_inbox?id=in.(${inbox.map(m => `"${m.id}"`).join(',')})`, { processed_at: new Date().toISOString() });

  const [conv] = await db.get(`/bot_conversations?select=*&phone=eq.${encodeURIComponent(phone)}`);
  const owner = isOwner(phone);

  // Chat tomado a mano por el dueño: el bot no contesta.
  if(!owner && conv.paused_until && new Date(conv.paused_until) > new Date()){
    await markDone();
    return true;
  }

  let llm;
  try{ llm = pickLLM(); }
  catch(e){
    console.error(e.message);
    await markDone();
    if(owner) await sendText(conv.wa_id, '⚠️ ' + e.message);
    return true;
  }

  const now = new Date();
  const idleHours = conv.last_message_at ? (now - new Date(conv.last_message_at)) / 3600000 : Infinity;
  let history = Array.isArray(conv.history) ? conv.history : [];
  let sessionContext = conv.session_context;
  let pending = Array.isArray(conv.pending_actions) ? conv.pending_actions : [];
  // Charla nueva si pasó mucho tiempo, si es muy larga, o si cambió la IA
  // (cada una guarda el historial en su propio formato).
  const fresh = !sessionContext || idleHours > SESSION_IDLE_HOURS || history.length > SESSION_MAX_MESSAGES || conv.llm !== llm.name;
  if(fresh){
    history = [];
    pending = [];
    sessionContext = await buildSessionContext(phone, owner, conv.name);
  }

  const userText = inbox.map(messageText).join('\n');
  const save = (fields) => db.patch(`/bot_conversations?phone=eq.${encodeURIComponent(phone)}`, {
    last_message_at: now.toISOString(),
    session_context: sessionContext,
    llm: llm.name,
    ...(fresh ? { session_started: now.toISOString() } : {}),
    ...fields,
  });

  // Modo dueño: respuesta a acciones que esperaban confirmación. El "sí"
  // lo resuelve el código, sin pasar por la IA.
  let note = '';
  if(owner && pending.length){
    if(CONFIRM_RE.test(userText) && userText.trim().length <= 40){
      const lines = [];
      for(const action of pending){
        try{ lines.push('✅ ' + await executeAction(action)); }
        catch(e){ lines.push(`❌ No se pudo: ${action.resumen.split('\n')[0]} — ${e.message}`); }
      }
      const reply = lines.join('\n');
      history.push(llm.userTurn(userText), llm.assistantTurn(reply));
      await save({ history, pending_actions: [] });
      await sendText(conv.wa_id, reply);
      await markDone();
      return true;
    }
    note = '\n\n(Sistema: los cambios que quedaron pendientes NO se ejecutaron porque Matías no confirmó; se descartaron.)';
    pending = [];
  }

  const ctx = {
    phone,
    waId: conv.wa_id,
    profileName: conv.name,
    wholesale: /— MAYORISTA/.test(sessionContext),
    paused: false,
    newPending: [],
    queueAction(a){ this.newPending.push(a); },
  };

  // Se trabaja sobre una copia: si algo falla a mitad, el historial
  // guardado queda como estaba (sin una herramienta colgada sin respuesta).
  const userTurn = llm.userTurn(`[${nowARText()}]\n${userText}${note}`);
  const args = {
    owner,
    system: [owner ? OWNER_PROMPT : CUSTOMER_PROMPT, sessionContext],
    tools: owner ? ownerTools : customerTools,
    ctx,
    deadline,
  };
  let turn = [...history, userTurn];

  let reply;
  try{
    try{
      reply = await llm.run({ ...args, history: turn });
    }catch(e){
      // Un 400 suele ser un historial que el modelo no acepta (ej: cambió
      // de versión): se reintenta una vez arrancando la charla de cero.
      if(e.status !== 400 || !history.length) throw e;
      console.warn('Historial rechazado, se reinicia la charla:', e.message);
      turn = [userTurn];
      reply = await llm.run({ ...args, history: turn });
    }
  }catch(e){
    console.error('llm.run', e);
    await markDone();
    const saturated = [429, 503].includes(e.status);
    if(owner){
      await sendText(conv.wa_id, saturated
        ? '⚠️ La IA gratuita está saturada en este momento. Probá de nuevo en un rato.'
        : '⚠️ Error del bot: ' + e.message);
    }else{
      await sendText(conv.wa_id, 'Perdón, estoy con un problema técnico. Ya le aviso a alguien del local para que te responda.');
      await notifyOwner(`⚠️ El bot no pudo responderle a ${conv.name || phone} (${phone})${saturated ? ' (IA saturada)' : ''}: ${e.message}\nwa.me/${conv.wa_id}`);
    }
    return true;
  }

  if(reply === null){
    reply = owner
      ? 'No puedo ayudarte con eso.'
      : 'Perdón, con eso no te puedo ayudar. Si querés te comunico con alguien del local.';
    turn.push(llm.assistantTurn(reply));
  }

  let outgoing = toWhatsApp(reply);
  if(ctx.newPending.length){
    outgoing += `\n\n*Para confirmar:*\n${ctx.newPending.map(a => a.resumen).join('\n\n')}\n\nRespondé *sí* para ejecutar, o cualquier otra cosa para descartar.`;
  }

  await save({ history: llm.sanitizeForSave(turn), pending_actions: ctx.newPending });
  if(outgoing) await sendText(conv.wa_id, outgoing);
  await markDone();
  return true;
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// Contesta el chat de un teléfono. Si otra llamada ya lo está contestando,
// espera: o esa llamada levanta este mensaje junto con los suyos, o se
// libera el chat y lo contesta esta. Cada llamada de Vercel dura como
// máximo 60 s, así que solo arranca un turno nuevo si le queda tiempo.
export async function handlePhone(phone, messageId){
  const started = Date.now();
  const timeLeft = () => 57000 - (Date.now() - started);
  const done = async () => {
    const rows = await db.get(`/bot_inbox?select=processed_at&id=eq.${encodeURIComponent(messageId)}`);
    return !rows[0] || !!rows[0].processed_at;
  };

  while(timeLeft() > 3000){
    if(await done()) return;
    if(await db.rpc('bot_try_lock', { p_phone: phone, p_seconds: 65 })){
      try{
        await processBatch(phone, Date.now() + timeLeft() - 2000);
      }finally{
        await db.rpc('bot_unlock', { p_phone: phone });
      }
      continue; // vuelve a chequear que este mensaje haya quedado contestado
    }
    await sleep(2500);
  }
}
