// Avisos al dueño (derivaciones, notas de pedidos, errores).
//
// Va por dos lados: ntfy (el mismo canal que ya avisa los pedidos nuevos,
// llega siempre) y WhatsApp al número del dueño. WhatsApp solo deja que el
// negocio escriba primero si esa persona le habló al número en las últimas
// 24 h, así que ese envío puede fallar y no pasa nada.

import { sendText } from './wa.js';

const NTFY_TOPIC = process.env.NTFY_TOPIC || 'sabores-royal-pedidos-13f559350aa4';

export function ownerWaIds(){
  return String(process.env.OWNER_PHONES || '')
    .split(',')
    .map(s => s.replace(/\D/g, ''))
    .filter(Boolean);
}

export async function notifyOwner(text){
  const jobs = [
    fetch('https://ntfy.sh/' + NTFY_TOPIC, {
      method: 'POST',
      headers: { Title: 'Bot WhatsApp - Sabores Royal', Tags: 'robot' },
      body: text,
    }),
    ...ownerWaIds().map(id => sendText(id, text)),
  ];
  const results = await Promise.allSettled(jobs);
  for(const r of results){
    if(r.status === 'rejected') console.warn('notifyOwner:', r.reason?.message || r.reason);
  }
}
