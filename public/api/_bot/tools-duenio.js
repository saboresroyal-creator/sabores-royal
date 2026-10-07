// Herramientas del MODO DUEÑO (mensajes que llegan desde OWNER_PHONES).
//
// Las de consulta se ejecutan directo. Las que modifican datos NO se
// ejecutan cuando Claude las llama: quedan como "acción pendiente" con un
// resumen armado acá (con los valores reales de la base) y recién corren
// cuando el dueño contesta "sí" — eso lo resuelve agent.js en código, no
// depende de que el modelo se acuerde de preguntar.

import { db, normalizePhone, getSetting, setSetting, todayAR } from './db.js';
import { money, searchProducts, getProductsByIds, activePromo } from './catalogo.js';
import { sendText } from './wa.js';

const ORDER_STATUSES = ['Pendiente', 'Revision', 'Listo', 'Entregado'];
const FINANZAS = {
  deudas_proveedores: 'supplier_debts',
  cheques_proveedores: 'supplier_checks',
  alquiler: 'rent_ledger',
};

function dayRange(desde, hasta){
  const d = /^\d{4}-\d{2}-\d{2}$/.test(desde || '') ? desde : todayAR();
  const h = /^\d{4}-\d{2}-\d{2}$/.test(hasta || '') ? hasta : d;
  const end = new Date(h + 'T00:00:00-03:00');
  end.setUTCDate(end.getUTCDate() + 1);
  return { from: new Date(d + 'T00:00:00-03:00').toISOString(), to: end.toISOString(), d, h };
}

function sumBy(rows, keyFn, valFn){
  const out = {};
  for(const r of rows){
    const k = keyFn(r) || 'sin dato';
    out[k] = (out[k] || 0) + valFn(r);
  }
  return out;
}

function productAdminView(p){
  const promo = activePromo(p);
  return {
    id: p.id,
    nombre: p.name,
    categoria: [p.section, p.cat, p.sub].filter(Boolean).join(' / '),
    precio: p.sell_by_weight ? `${money(p.price_per_kg)}/kg` : money(p.price),
    precio_mayorista: p.sell_by_weight
      ? (p.wholesale_price_per_kg ? `${money(p.wholesale_price_per_kg)}/kg` : null)
      : (p.wholesale_price ? money(p.wholesale_price) : null),
    oferta: promo !== null ? `${money(promo)}${p.super_offer ? ' (súper oferta)' : ` hasta ${p.promo_until}`}` : null,
    stock: p.sell_by_weight ? 'por peso' : p.stock,
    oculto: !!p.hidden,
    codigo_barras: p.barcode || null,
    caja: p.display_qty ? `x${p.display_qty}${p.display_discount ? ` (-${p.display_discount}% minorista)` : ''}` : null,
  };
}

async function findConversationPhone(telefono){
  const phone = normalizePhone(telefono);
  const rows = await db.get(`/bot_conversations?select=phone,wa_id,name,last_message_at&phone=eq.${encodeURIComponent(phone)}`);
  return rows[0] || null;
}

// ---------------------------------------------------------------------
// Acciones que modifican datos: preparar (arma el resumen) / ejecutar.
// ---------------------------------------------------------------------
const PRODUCT_FIELDS = {
  precio: 'price',
  precio_mayorista: 'wholesale_price',
  precio_por_kg: 'price_per_kg',
  precio_mayorista_por_kg: 'wholesale_price_per_kg',
  stock: 'stock',
  precio_oferta: 'promo_price',
  oferta_hasta: 'promo_until',
  oculto: 'hidden',
};

const actions = {
  async modificar_productos({ cambios }){
    const products = await getProductsByIds(cambios.map(c => c.producto_id));
    const byId = new Map(products.map(p => [Number(p.id), p]));
    const lines = [];
    const patches = [];
    for(const c of cambios){
      const p = byId.get(Number(c.producto_id));
      if(!p) return { error: `No existe el producto ${c.producto_id}.` };
      const patch = {};
      const diffs = [];
      for(const [campo, col] of Object.entries(PRODUCT_FIELDS)){
        if(c[campo] === undefined) continue;
        let val = c[campo];
        if(['precio', 'precio_mayorista', 'precio_por_kg', 'precio_mayorista_por_kg', 'precio_oferta'].includes(campo)){
          val = Math.round(Number(val));
          if(!(val > 0)) return { error: `Precio inválido para "${p.name}".` };
        }
        if(campo === 'stock'){
          val = Math.round(Number(val));
          if(!(val >= 0)) return { error: `Stock inválido para "${p.name}".` };
        }
        const before = p[col];
        const fmt = v => v === null || v === undefined || v === '' ? '—' : (['stock', 'oculto', 'oferta_hasta'].includes(campo) ? String(v) : money(v));
        diffs.push(`${campo.replace(/_/g, ' ')} ${fmt(before)} → ${fmt(val)}`);
        patch[col] = val;
      }
      if(c.quitar_oferta){
        patch.promo_price = null; patch.promo_until = null; patch.super_offer = false;
        diffs.push('sin oferta');
      }
      if(!diffs.length) continue;
      lines.push(`• ${p.name} (#${p.id}): ${diffs.join(', ')}`);
      patches.push({ id: p.id, patch });
    }
    if(!patches.length) return { error: 'No hay ningún cambio para aplicar.' };
    return {
      resumen: `Modificar ${patches.length} producto(s):\n${lines.join('\n')}`,
      payload: { patches },
    };
  },

  async cambiar_estado_pedido({ pedido, estado }){
    if(!ORDER_STATUSES.includes(estado)) return { error: `Estado inválido. Opciones: ${ORDER_STATUSES.join(', ')}.` };
    const rows = await db.get(`/orders?select=id,customer_name,total,status&id=eq.${encodeURIComponent(pedido)}`);
    if(!rows[0]) return { error: `No existe el pedido ${pedido}.` };
    const o = rows[0];
    return { resumen: `Pedido ${o.id} de ${o.customer_name} (${money(o.total)}): ${o.status} → ${estado}`, payload: { pedido: o.id, estado } };
  },

  async cancelar_pedido({ pedido }){
    const rows = await db.get(`/orders?select=id,customer_name,total,status&id=eq.${encodeURIComponent(pedido)}`);
    if(!rows[0]) return { error: `No existe el pedido ${pedido}.` };
    const o = rows[0];
    if(o.status === 'Cancelado') return { error: 'Ese pedido ya está cancelado.' };
    return { resumen: `Cancelar el pedido ${o.id} de ${o.customer_name} (${money(o.total)}) y devolver el stock`, payload: { pedido: o.id } };
  },

  async enviar_mensaje({ telefono, texto }){
    const conv = await findConversationPhone(telefono);
    if(!conv || !conv.wa_id) return { error: 'Ese número nunca le escribió al WhatsApp del negocio, así que no se le puede mandar un mensaje libre (WhatsApp solo lo permite si el cliente escribió en las últimas 24 h).' };
    const hours = conv.last_message_at ? (Date.now() - new Date(conv.last_message_at).getTime()) / 3600000 : 999;
    if(hours > 24) return { error: `El último mensaje de ese cliente fue hace ${Math.round(hours)} h. WhatsApp solo permite responder dentro de las 24 h; pasado eso hay que escribirle desde el celular.` };
    return { resumen: `Mandarle a ${conv.name || conv.phone}:\n"${texto}"`, payload: { wa_id: conv.wa_id, texto } };
  },

  async actualizar_info_negocio({ texto }){
    return { resumen: `Reemplazar la info del negocio que el bot les da a los clientes por:\n${texto}`, payload: { texto } };
  },
};

const executors = {
  async modificar_productos({ patches }){
    for(const { id, patch } of patches) await db.patch(`/products?id=eq.${id}`, patch);
    return `${patches.length} producto(s) actualizado(s).`;
  },
  async cambiar_estado_pedido({ pedido, estado }){
    await db.patch(`/orders?id=eq.${encodeURIComponent(pedido)}`, { status: estado });
    return `Pedido ${pedido} ahora está en ${estado}.`;
  },
  async cancelar_pedido({ pedido }){
    await db.rpc('bot_cancel_order', { p_order_id: pedido });
    return `Pedido ${pedido} cancelado y stock devuelto.`;
  },
  async enviar_mensaje({ wa_id, texto }){
    await sendText(wa_id, texto);
    return 'Mensaje enviado.';
  },
  async actualizar_info_negocio({ texto }){
    await setSetting('bot_info', texto);
    return 'Info del negocio actualizada (los clientes la ven desde su próxima conversación).';
  },
};

export async function executeAction(action){
  return executors[action.tool](action.payload);
}

const PENDING_NOTE = 'Quedó PENDIENTE: el sistema le va a mostrar el resumen al dueño y lo ejecuta solo si responde "sí". No digas que ya está hecho.';

function writeTool(def){
  return {
    def,
    async run(input, ctx){
      const prepared = await actions[def.name](input);
      if(prepared.error) return prepared;
      ctx.queueAction({ tool: def.name, resumen: prepared.resumen, payload: prepared.payload });
      return { pendiente_de_confirmacion: prepared.resumen, nota: PENDING_NOTE };
    },
  };
}

export const ownerTools = [
  {
    def: {
      name: 'resumen_ventas',
      description: 'Ventas de un día o rango: caja del local (POS) y pedidos online/WhatsApp, con totales por medio de pago, por caja y productos más vendidos. Fechas en formato AAAA-MM-DD (hora Argentina). Sin fechas = hoy.',
      input_schema: {
        type: 'object',
        properties: {
          desde: { type: 'string' },
          hasta: { type: 'string', description: 'Inclusive. Si se omite, igual a desde.' },
        },
        additionalProperties: false,
      },
    },
    async run({ desde, hasta }){
      const r = dayRange(desde, hasta);
      const [pos, orders] = await Promise.all([
        db.get(`/pos_sales?select=caja,cajero,items,total,payment_method,status&created_at=gte.${r.from}&created_at=lt.${r.to}&status=neq.anulada&limit=20000`),
        db.get(`/orders?select=id,total,status,payment_method,items&created_at=gte.${r.from}&created_at=lt.${r.to}&status=neq.Cancelado&limit=20000`),
      ]);
      const top = {};
      for(const s of [...pos, ...orders]){
        for(const it of s.items || []){
          const k = it.name || String(it.id);
          top[k] = top[k] || { unidades: 0, total: 0 };
          top[k].unidades += it.grams ? 0 : Number(it.qty) || 0;
          top[k].total += Number(it.lineTotal) || (Number(it.price) || 0) * (Number(it.qty) || 0);
        }
      }
      const fmt = obj => Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, money(v)]));
      const posTotal = pos.reduce((a, s) => a + Number(s.total), 0);
      const ordTotal = orders.reduce((a, o) => a + Number(o.total), 0);
      return {
        periodo: r.d === r.h ? r.d : `${r.d} a ${r.h}`,
        total_general: money(posTotal + ordTotal),
        caja_local: {
          total: money(posTotal),
          ventas: pos.length,
          por_medio_de_pago: fmt(sumBy(pos, s => s.payment_method, s => Number(s.total))),
          por_caja: fmt(sumBy(pos, s => s.caja, s => Number(s.total))),
        },
        pedidos: {
          total: money(ordTotal),
          cantidad: orders.length,
          por_estado: sumBy(orders, o => o.status, () => 1),
        },
        mas_vendidos: Object.entries(top).sort((a, b) => b[1].total - a[1].total).slice(0, 10)
          .map(([n, v]) => `${n}: ${v.unidades ? v.unidades + ' u, ' : ''}${money(v.total)}`),
      };
    },
  },
  {
    def: {
      name: 'listar_pedidos',
      description: 'Lista pedidos (online/WhatsApp), los más nuevos primero. Filtrá por estado (Pendiente, Revision, Listo, Entregado, Cancelado) y/o por días hacia atrás.',
      input_schema: {
        type: 'object',
        properties: {
          estado: { type: 'string' },
          dias: { type: 'integer', description: 'Cuántos días hacia atrás (default 7)' },
        },
        additionalProperties: false,
      },
    },
    async run({ estado, dias }){
      const since = new Date(Date.now() - (dias || 7) * 86400000).toISOString();
      let path = `/orders?select=id,created_at,customer_name,client_phone,customer_address,total,status,payment_method,items&created_at=gte.${since}&order=created_at.desc&limit=40`;
      if(estado) path += `&status=eq.${encodeURIComponent(estado)}`;
      const rows = await db.get(path);
      return {
        pedidos: rows.map(o => ({
          pedido: o.id,
          fecha: new Date(new Date(o.created_at).getTime() - 3 * 3600000).toISOString().slice(0, 16).replace('T', ' '),
          cliente: `${o.customer_name} (${o.client_phone})`,
          direccion: o.customer_address || null,
          total: money(o.total),
          estado: o.status,
          pago: o.payment_method || null,
          items: (o.items || []).map(i => `${i.grams ? i.grams + ' g' : i.qty + ' x'} ${i.name}`),
        })),
      };
    },
  },
  {
    def: {
      name: 'buscar_productos',
      description: 'Busca productos con todos los datos internos (id, precios minorista/mayorista, oferta, stock exacto, oculto, código de barras). Usala antes de modificar un producto para tener su id.',
      input_schema: {
        type: 'object',
        properties: {
          busqueda: { type: 'string' },
          incluir_ocultos: { type: 'boolean' },
        },
        required: ['busqueda'],
        additionalProperties: false,
      },
    },
    async run({ busqueda, incluir_ocultos }){
      const rows = await searchProducts(busqueda, { includeHidden: incluir_ocultos !== false, limit: 60 });
      return {
        resultados: rows.slice(0, 60).map(productAdminView),
        ...(rows.length > 60 ? { aviso: 'Hay más de 60 resultados; afiná la búsqueda.' } : {}),
      };
    },
  },
  {
    def: {
      name: 'stock_bajo',
      description: 'Productos visibles (no ocultos, no por peso) con stock menor o igual al umbral.',
      input_schema: {
        type: 'object',
        properties: { umbral: { type: 'integer', description: 'Default 3' } },
        additionalProperties: false,
      },
    },
    async run({ umbral }){
      const n = Number.isFinite(umbral) ? umbral : 3;
      const rows = await db.get(`/products?select=id,name,stock,cat&hidden=eq.false&sell_by_weight=not.is.true&stock=lte.${n}&order=stock.asc,name.asc&limit=150`);
      return { cantidad: rows.length, productos: rows.map(p => `#${p.id} ${p.name}: ${p.stock}`) };
    },
  },
  {
    def: {
      name: 'buscar_cliente',
      description: 'Busca clientes por nombre, razón social o teléfono. Devuelve sus datos y sus últimos pedidos.',
      input_schema: {
        type: 'object',
        properties: { busqueda: { type: 'string' } },
        required: ['busqueda'],
        additionalProperties: false,
      },
    },
    async run({ busqueda }){
      const q = String(busqueda).trim();
      const digits = q.replace(/\D/g, '');
      let rows;
      if(digits.length >= 6){
        rows = await db.get(`/clients?select=*&phone=like.*${digits.slice(-8)}*&limit=10`);
      }else{
        const w = q.replace(/[^\p{L}\p{N} ]/gu, '').trim();
        rows = await db.get(`/clients?select=*&or=(full_name.ilike.*${w}*,razon_social.ilike.*${w}*)&limit=10`);
      }
      const out = [];
      for(const c of rows){
        const orders = await db.get(`/orders?select=id,created_at,total,status&client_phone=eq.${encodeURIComponent(c.phone)}&status=neq.Cancelado&order=created_at.desc&limit=5`);
        out.push({
          nombre: c.full_name,
          telefono: c.phone,
          mayorista: !!c.wholesale,
          rubro: c.rubro || null,
          direccion: c.address || null,
          cuit: c.cuit || null,
          razon_social: c.razon_social || null,
          puntos: c.points || 0,
          numero_cliente: c.client_number || null,
          ultimos_pedidos: orders.map(o => `${o.id} ${o.created_at.slice(0, 10)} ${money(o.total)} ${o.status}`),
        });
      }
      return { clientes: out };
    },
  },
  {
    def: {
      name: 'leer_finanzas',
      description: 'Lee los registros internos del panel admin: deudas con proveedores, cheques a proveedores o alquiler. Devuelve los datos tal como están guardados (JSON); interpretalos para responder.',
      input_schema: {
        type: 'object',
        properties: { tipo: { type: 'string', enum: Object.keys(FINANZAS) } },
        required: ['tipo'],
        additionalProperties: false,
      },
    },
    async run({ tipo }){
      const raw = await getSetting(FINANZAS[tipo]);
      if(!raw) return { aviso: 'No hay datos guardados.' };
      return { hoy: todayAR(), datos: raw.length > 60000 ? raw.slice(0, 60000) + '…(recortado)' : raw };
    },
  },
  {
    def: {
      name: 'ver_info_negocio',
      description: 'Muestra el texto de info del negocio que el bot usa para responder a los clientes (horarios, envíos, pagos...).',
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
    },
    async run(){
      return { info: await getSetting('bot_info') };
    },
  },
  {
    def: {
      name: 'pausar_bot',
      description: 'Silencia al bot en el chat de un cliente (para atenderlo a mano). Se ejecuta en el momento.',
      input_schema: {
        type: 'object',
        properties: {
          telefono: { type: 'string' },
          horas: { type: 'integer', description: 'Default 12' },
        },
        required: ['telefono'],
        additionalProperties: false,
      },
    },
    async run({ telefono, horas }){
      const phone = normalizePhone(telefono);
      const until = new Date(Date.now() + (horas || 12) * 3600000).toISOString();
      const rows = await db.patch(`/bot_conversations?phone=eq.${encodeURIComponent(phone)}`, { paused_until: until });
      return rows.length ? { ok: true, pausado_hasta: until } : { error: 'Ese número no tiene conversación con el bot.' };
    },
  },
  {
    def: {
      name: 'reactivar_bot',
      description: 'Vuelve a activar al bot en el chat de un cliente. Se ejecuta en el momento.',
      input_schema: {
        type: 'object',
        properties: { telefono: { type: 'string' } },
        required: ['telefono'],
        additionalProperties: false,
      },
    },
    async run({ telefono }){
      const phone = normalizePhone(telefono);
      const rows = await db.patch(`/bot_conversations?phone=eq.${encodeURIComponent(phone)}`, { paused_until: null });
      return rows.length ? { ok: true } : { error: 'Ese número no tiene conversación con el bot.' };
    },
  },
  writeTool({
    name: 'modificar_productos',
    description: 'Cambia precio, precio mayorista, stock, oferta u ocultar/mostrar de uno o varios productos (para aumentos masivos, pasá todos en una sola llamada con el precio final ya calculado y redondeado). Requiere confirmación del dueño.',
    input_schema: {
      type: 'object',
      properties: {
        cambios: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              producto_id: { type: 'integer' },
              precio: { type: 'number' },
              precio_mayorista: { type: 'number' },
              precio_por_kg: { type: 'number' },
              precio_mayorista_por_kg: { type: 'number' },
              stock: { type: 'integer' },
              precio_oferta: { type: 'number' },
              oferta_hasta: { type: 'string', description: 'AAAA-MM-DD' },
              quitar_oferta: { type: 'boolean' },
              oculto: { type: 'boolean' },
            },
            required: ['producto_id'],
            additionalProperties: false,
          },
        },
      },
      required: ['cambios'],
      additionalProperties: false,
    },
  }),
  writeTool({
    name: 'cambiar_estado_pedido',
    description: `Cambia el estado de un pedido (${ORDER_STATUSES.join(', ')}). Para cancelar usá cancelar_pedido. Requiere confirmación.`,
    input_schema: {
      type: 'object',
      properties: {
        pedido: { type: 'string', description: 'Id del pedido, ej: SR2610061530xx' },
        estado: { type: 'string', enum: ORDER_STATUSES },
      },
      required: ['pedido', 'estado'],
      additionalProperties: false,
    },
  }),
  writeTool({
    name: 'cancelar_pedido',
    description: 'Cancela un pedido y devuelve el stock. Requiere confirmación.',
    input_schema: {
      type: 'object',
      properties: { pedido: { type: 'string' } },
      required: ['pedido'],
      additionalProperties: false,
    },
  }),
  writeTool({
    name: 'enviar_mensaje',
    description: 'Le manda un WhatsApp a un cliente desde el número del negocio (solo si el cliente escribió en las últimas 24 h). Requiere confirmación.',
    input_schema: {
      type: 'object',
      properties: {
        telefono: { type: 'string' },
        texto: { type: 'string' },
      },
      required: ['telefono', 'texto'],
      additionalProperties: false,
    },
  }),
  writeTool({
    name: 'actualizar_info_negocio',
    description: 'Reemplaza el texto completo de info del negocio que ven los clientes. Primero leelo con ver_info_negocio y mandá el texto completo ya editado. Requiere confirmación.',
    input_schema: {
      type: 'object',
      properties: { texto: { type: 'string' } },
      required: ['texto'],
      additionalProperties: false,
    },
  }),
];
