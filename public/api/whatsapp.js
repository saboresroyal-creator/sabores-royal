import crypto from 'node:crypto';
import { waitUntil } from '@vercel/functions';
import { db, normalizePhone } from './_bot/db.js';
import { markReadTyping } from './_bot/wa.js';
import { handlePhone, isOwner } from './_bot/agent.js';

// Webhook de WhatsApp Cloud API (Meta). Meta llama acá cada vez que entra
// un mensaje al número del negocio. Contestamos 200 al toque (si no, Meta
// reintenta y llegan duplicados) y la respuesta con Claude sigue corriendo
// en segundo plano con waitUntil.
//
// Variables de entorno en Vercel:
//   WHATSAPP_VERIFY_TOKEN      texto inventado, el mismo que se pone en Meta al configurar el webhook
//   WHATSAPP_APP_SECRET        "Clave secreta de la app" (Meta > Configuración de la app > Básica)
//   WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID   (ver _bot/wa.js)
//   SUPABASE_SERVICE_ROLE_KEY, ANTHROPIC_API_KEY
//   OWNER_PHONES               números del dueño separados por coma, ej: 5493411234567

export const config = { maxDuration: 60 };

// Si el dueño contesta un chat a mano desde la app de WhatsApp Business,
// el bot se calla en ese chat por estas horas.
const MANUAL_REPLY_PAUSE_HOURS = 12;

async function readRawBody(req){
  const chunks = [];
  for await (const chunk of req) chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  return Buffer.concat(chunks);
}

function validSignature(raw, header){
  const secret = process.env.WHATSAPP_APP_SECRET;
  if(!secret || !header || !header.startsWith('sha256=')) return false;
  const expected = crypto.createHmac('sha256', secret).update(raw).digest('hex');
  const got = header.slice(7);
  return got.length === expected.length && crypto.timingSafeEqual(Buffer.from(got), Buffer.from(expected));
}

function extractBody(m){
  switch(m.type){
    case 'text': return m.text?.body || '';
    case 'button': return m.button?.text || '';
    case 'interactive': return m.interactive?.button_reply?.title || m.interactive?.list_reply?.title || '';
    case 'image': return m.image?.caption || '';
    case 'video': return m.video?.caption || '';
    case 'document': return m.document?.caption || m.document?.filename || '';
    case 'location': return `[ubicación: ${m.location?.name || ''} ${m.location?.address || ''} (${m.location?.latitude}, ${m.location?.longitude})]`;
    default: return '';
  }
}

async function onMessage(m, contacts){
  const waId = m.from;
  const phone = normalizePhone(waId);
  const name = contacts.find(c => c.wa_id === waId)?.profile?.name || null;

  // Dedupe: si Meta reenvía un mensaje que ya teníamos, el insert no devuelve nada.
  const inserted = await db.insert('bot_inbox', { id: m.id, phone, type: m.type, body: extractBody(m) },
    'resolution=ignore-duplicates,return=representation');
  if(!inserted || !inserted.length) return;

  await db.insert('bot_conversations?on_conflict=phone', { phone, wa_id: waId, ...(name ? { name } : {}) },
    'resolution=merge-duplicates,return=minimal');

  const [conv] = await db.get(`/bot_conversations?select=paused_until&phone=eq.${encodeURIComponent(phone)}`);
  const paused = !isOwner(phone) && conv?.paused_until && new Date(conv.paused_until) > new Date();
  if(!paused) await markReadTyping(m.id);

  await handlePhone(phone);
}

// Mensaje mandado a mano desde la app de WhatsApp Business (modo
// coexistencia): el dueño tomó ese chat, el bot se corre.
async function onManualReply(echo){
  if(!echo.to) return;
  const phone = normalizePhone(echo.to);
  if(isOwner(phone)) return;
  const until = new Date(Date.now() + MANUAL_REPLY_PAUSE_HOURS * 3600000).toISOString();
  await db.insert('bot_conversations?on_conflict=phone', { phone, wa_id: echo.to, paused_until: until },
    'resolution=merge-duplicates,return=minimal');
}

export default async function handler(req, res){
  if(req.method === 'GET'){
    const q = req.query || {};
    if(q['hub.mode'] === 'subscribe' && q['hub.verify_token'] && q['hub.verify_token'] === process.env.WHATSAPP_VERIFY_TOKEN){
      return res.status(200).send(q['hub.challenge']);
    }
    return res.status(403).send('forbidden');
  }
  if(req.method !== 'POST') return res.status(405).send('method not allowed');

  const raw = await readRawBody(req);
  if(!validSignature(raw, req.headers['x-hub-signature-256'])){
    return res.status(401).send('bad signature');
  }

  let payload;
  try{ payload = JSON.parse(raw.toString('utf8')); }
  catch{ return res.status(400).send('bad json'); }

  const jobs = [];
  for(const entry of payload.entry || []){
    for(const change of entry.changes || []){
      const v = change.value || {};
      if(change.field === 'messages'){
        for(const m of v.messages || []) jobs.push(onMessage(m, v.contacts || []));
      }else if(change.field === 'smb_message_echoes'){
        for(const echo of v.message_echoes || []) jobs.push(onManualReply(echo));
      }
    }
  }

  waitUntil(Promise.allSettled(jobs).then(results => {
    for(const r of results) if(r.status === 'rejected') console.error('webhook job:', r.reason);
  }));
  return res.status(200).send('ok');
}
