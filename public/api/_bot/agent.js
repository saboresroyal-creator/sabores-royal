// Cerebro del bot: toma los mensajes sin procesar de un teléfono, arma el
// turno para Claude, corre las herramientas y contesta por WhatsApp.

import Anthropic from '@anthropic-ai/sdk';
import { db, normalizePhone, getSetting, nowARText } from './db.js';
import { sendText } from './wa.js';
import { customerTools } from './tools-clientes.js';
import { ownerTools, executeAction } from './tools-duenio.js';
import { CUSTOMER_PROMPT, OWNER_PROMPT } from './prompts.js';
import { notifyOwner, ownerWaIds } from './notify.js';

const MODEL = 'claude-opus-5-5';
const SESSION_IDLE_HOURS = 12;   // charla nueva si pasó este tiempo sin mensajes
const SESSION_MAX_MESSAGES = 80; // o si el historial ya es muy largo
const MAX_TOOL_ROUNDS = 8;
const CONFIRM_RE = /^\s*(s[ií]+|dale|ok|okey|confirmo|confirmado|hacelo|de una|va)\b/i;

const client = new Anthropic();

export function isOwner(phone){
  return ownerWaIds().some(id => normalizePhone(id) === phone);
}

function messageText(m){
  if(m.type === 'text') return m.body;
  if(m.type === 'audio') return '[mandó un audio]';
  if(m.type === 'image') return m.body ? `[mandó una foto con el texto: ${m.body}]` : '[mandó una foto]';
  return m.body || `[mandó un mensaje de tipo ${m.type}]`;
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

// Corre Claude con herramientas hasta que contesta con texto.
async function runClaude({ owner, sessionContext, history, ctx }){
  const tools = owner ? ownerTools : customerTools;
  const byName = new Map(tools.map(t => [t.def.name, t]));
  const messages = history;

  for(let round = 0; round < MAX_TOOL_ROUNDS; round++){
    const response = await client.beta.messages.create({
      model: MODEL,
      max_tokens: 16000,
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      output_config: { effort: owner ? 'medium' : 'low' },
      cache_control: { type: 'ephemeral' },
      system: [
        { type: 'text', text: owner ? OWNER_PROMPT : CUSTOMER_PROMPT },
        { type: 'text', text: sessionContext },
      ],
      tools: tools.map(t => t.def),
      messages,
    });
    messages.push({ role: 'assistant', content: response.content });

    if(response.stop_reason === 'refusal'){
      return owner
        ? 'No puedo ayudarte con eso.'
        : 'Perdón, con eso no te puedo ayudar. Si querés te comunico con alguien del local.';
    }
    if(response.stop_reason !== 'tool_use'){
      return response.content.filter(b => b.type === 'text').map(b => b.text).join('\n').trim();
    }

    const calls = response.content.filter(b => b.type === 'tool_use');
    const results = await Promise.all(calls.map(async call => {
      const tool = byName.get(call.name);
      try{
        if(!tool) throw new Error('Herramienta desconocida: ' + call.name);
        const out = await tool.run(call.input || {}, ctx);
        return { type: 'tool_result', tool_use_id: call.id, content: JSON.stringify(out), ...(out && out.error ? { is_error: true } : {}) };
      }catch(e){
        console.error('tool', call.name, e);
        return { type: 'tool_result', tool_use_id: call.id, content: 'Error del sistema: ' + e.message, is_error: true };
      }
    }));
    messages.push({ role: 'user', content: results });
  }
  return 'Se me complicó resolver esto. ¿Me lo pedís de otra forma?';
}

// Procesa todos los mensajes pendientes de un teléfono en un solo turno.
// Devuelve false si no había nada que procesar.
async function processBatch(phone){
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

  const now = new Date();
  const idleHours = conv.last_message_at ? (now - new Date(conv.last_message_at)) / 3600000 : Infinity;
  let history = Array.isArray(conv.history) ? conv.history : [];
  let sessionContext = conv.session_context;
  let pending = Array.isArray(conv.pending_actions) ? conv.pending_actions : [];
  const fresh = !sessionContext || idleHours > SESSION_IDLE_HOURS || history.length > SESSION_MAX_MESSAGES;
  if(fresh){
    history = [];
    pending = [];
    sessionContext = await buildSessionContext(phone, owner, conv.name);
  }

  const userText = inbox.map(messageText).join('\n');
  const save = (fields) => db.patch(`/bot_conversations?phone=eq.${encodeURIComponent(phone)}`, {
    last_message_at: now.toISOString(),
    session_context: sessionContext,
    ...(fresh ? { session_started: now.toISOString() } : {}),
    ...fields,
  });

  // Modo dueño: respuesta a acciones que esperaban confirmación. El "sí"
  // lo resuelve el código, sin pasar por Claude.
  let note = '';
  if(owner && pending.length){
    if(CONFIRM_RE.test(userText) && userText.trim().length <= 40){
      const lines = [];
      for(const action of pending){
        try{ lines.push('✅ ' + await executeAction(action)); }
        catch(e){ lines.push(`❌ No se pudo: ${action.resumen.split('\n')[0]} — ${e.message}`); }
      }
      const reply = lines.join('\n');
      history.push({ role: 'user', content: userText }, { role: 'assistant', content: reply });
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
  // guardado queda como estaba (sin un tool_use colgado sin respuesta).
  const turn = history.slice();
  turn.push({ role: 'user', content: `[${nowARText()}]\n${userText}${note}` });

  let reply;
  try{
    reply = await runClaude({ owner, sessionContext, history: turn, ctx });
  }catch(e){
    console.error('runClaude', e);
    await markDone();
    if(owner){
      await sendText(conv.wa_id, '⚠️ Error del bot: ' + e.message);
    }else{
      await sendText(conv.wa_id, 'Perdón, estoy con un problema técnico. Ya le aviso a alguien del local para que te responda.');
      await notifyOwner(`⚠️ El bot falló con ${conv.name || phone} (${phone}): ${e.message}\nwa.me/${conv.wa_id}`);
    }
    return true;
  }

  let outgoing = reply;
  if(ctx.newPending.length){
    outgoing += `\n\n*Para confirmar:*\n${ctx.newPending.map(a => a.resumen).join('\n\n')}\n\nRespondé *sí* para ejecutar, o cualquier otra cosa para descartar.`;
  }

  await save({ history: turn, pending_actions: ctx.newPending });
  if(outgoing) await sendText(conv.wa_id, outgoing);
  await markDone();
  return true;
}

export async function handlePhone(phone){
  for(let attempt = 0; attempt < 3; attempt++){
    const got = await db.rpc('bot_try_lock', { p_phone: phone, p_seconds: 90 });
    if(!got) return; // otra función ya está contestando este chat y va a levantar este mensaje
    try{
      while(await processBatch(phone)){ /* sigue mientras haya mensajes nuevos */ }
    }finally{
      await db.rpc('bot_unlock', { p_phone: phone });
    }
    // Un mensaje pudo entrar justo entre el último chequeo y el unlock.
    const left = await db.get(`/bot_inbox?select=id&phone=eq.${encodeURIComponent(phone)}&processed_at=is.null&limit=1`);
    if(!left.length) return;
  }
}
