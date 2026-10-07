// Herramientas que Claude puede usar cuando habla con un CLIENTE.
// ctx = { phone, waId, profileName, client, conv }

import { db } from './db.js';
import {
  MIN_WHOLESALE_ORDER, money, searchProducts, getProductsByIds,
  productForCustomer, lineTotal, unitPrice, kgPrice, activePromo,
} from './catalogo.js';
import { notifyOwner } from './notify.js';

const HANDOFF_HOURS = 12;

export const customerTools = [
  {
    def: {
      name: 'buscar_productos',
      description: 'Busca productos del catálogo por nombre, marca o categoría y devuelve precio (ya calculado para este cliente: minorista o mayorista) y disponibilidad. Usala siempre antes de dar un precio o confirmar stock; no inventes precios.',
      input_schema: {
        type: 'object',
        properties: {
          busqueda: { type: 'string', description: 'Palabras clave, ej: "alfajor jorgito" o "galletitas sin tacc"' },
        },
        required: ['busqueda'],
        additionalProperties: false,
      },
    },
    async run({ busqueda }, ctx){
      const rows = await searchProducts(busqueda);
      const more = rows.length > 20;
      return {
        resultados: rows.slice(0, 20).map(p => productForCustomer(p, ctx.wholesale)),
        ...(more ? { aviso: 'Hay más resultados; pedile al cliente que sea más específico.' } : {}),
        ...(rows.length ? {} : { aviso: 'No se encontró nada. Probá con otras palabras (sinónimos, marca, singular).' }),
      };
    },
  },
  {
    def: {
      name: 'ver_ofertas',
      description: 'Lista los productos en oferta hoy. Los mayoristas no tienen ofertas (tienen su propio precio).',
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
    },
    async run(_input, ctx){
      if(ctx.wholesale) return { resultados: [], aviso: 'Los clientes mayoristas no tienen ofertas minoristas: ya tienen precio mayorista en todo.' };
      const rows = await db.get('/products?select=*&hidden=eq.false&promo_price=not.is.null&order=name.asc&limit=200');
      const on = rows.filter(p => activePromo(p) !== null);
      return { resultados: on.slice(0, 30).map(p => productForCustomer(p, false)) };
    },
  },
  {
    def: {
      name: 'crear_pedido',
      description: 'Carga el pedido en el sistema y descuenta el stock. Usala SOLO después de mostrarle al cliente el detalle con el total y que él confirme explícitamente. Los precios los calcula el sistema.',
      input_schema: {
        type: 'object',
        properties: {
          items: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                producto_id: { type: 'integer' },
                cantidad: { type: 'integer', description: 'Unidades. Para productos por peso poné 1 y usá gramos.' },
                gramos: { type: 'integer', description: 'Solo para productos que se venden por peso.' },
              },
              required: ['producto_id', 'cantidad'],
              additionalProperties: false,
            },
          },
          nombre: { type: 'string', description: 'Nombre del cliente (o del comercio)' },
          direccion: { type: 'string', description: 'Dirección de entrega, o "retira en el local"' },
          metodo_pago: { type: 'string', description: 'Ej: efectivo, transferencia' },
          notas: { type: 'string' },
        },
        required: ['items', 'nombre'],
        additionalProperties: false,
      },
    },
    async run(input, ctx){
      const products = await getProductsByIds(input.items.map(i => i.producto_id));
      const byId = new Map(products.map(p => [Number(p.id), p]));
      const items = [];
      for(const it of input.items){
        const p = byId.get(Number(it.producto_id));
        if(!p || p.hidden) return { error: `El producto ${it.producto_id} no existe. Buscalo de nuevo con buscar_productos.` };
        if(p.sell_by_weight){
          const grams = Number(it.gramos) || 0;
          if(grams <= 0) return { error: `"${p.name}" se vende por peso: falta indicar los gramos.` };
          if(p.min_grams && grams < p.min_grams) return { error: `"${p.name}" tiene un mínimo de ${p.min_grams} g.` };
          items.push({ id: Number(p.id), name: p.name, price: kgPrice(p, ctx.wholesale), qty: 1, grams, lineTotal: lineTotal(p, { qty: 1, grams }, ctx.wholesale) });
        }else{
          const qty = Number(it.cantidad) || 0;
          if(qty <= 0) return { error: `Cantidad inválida para "${p.name}".` };
          items.push({ id: Number(p.id), name: p.name, price: unitPrice(p, ctx.wholesale), qty, grams: null, lineTotal: lineTotal(p, { qty }, ctx.wholesale) });
        }
      }
      const total = items.reduce((s, i) => s + i.lineTotal, 0);
      const belowMin = ctx.wholesale && total < MIN_WHOLESALE_ORDER;
      try{
        const order = await db.rpc('create_order', {
          p_phone: ctx.phone,
          p_name: input.nombre,
          p_address: input.direccion || null,
          p_items: items,
          p_discount_pct: null,
          p_discount_amount: null,
          p_total: total,
          p_payment_method: input.metodo_pago || null,
          p_status: belowMin ? 'Revision' : null,
        });
        // create_order no guarda notas; se las mandamos al dueño para que no se pierdan.
        if(input.notas){
          await notifyOwner(`📝 Nota del pedido ${order.id} (${input.nombre}): ${input.notas}`).catch(() => {});
        }
        return {
          ok: true,
          pedido: order.id,
          total: money(total),
          detalle: items.map(i => `${i.grams ? i.grams + ' g' : i.qty + ' x'} ${i.name}: ${money(i.lineTotal)}`),
          ...(belowMin ? { aviso: `Quedó por debajo del mínimo mayorista (${money(MIN_WHOLESALE_ORDER)}): queda en revisión y el local lo confirma antes de prepararlo.` } : {}),
        };
      }catch(e){
        if(String(e.message).includes('sin_stock')){
          return { error: `No hay stock suficiente de "${e.message.split(':').slice(1).join(':')}". Ofrecé ajustar la cantidad o un reemplazo.` };
        }
        throw e;
      }
    },
  },
  {
    def: {
      name: 'mis_pedidos',
      description: 'Muestra los últimos pedidos de este cliente con su estado.',
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
    },
    async run(_input, ctx){
      const rows = await db.get(`/orders?select=id,created_at,total,status,items&client_phone=eq.${encodeURIComponent(ctx.phone)}&order=created_at.desc&limit=5`);
      return {
        pedidos: rows.map(o => ({
          pedido: o.id,
          fecha: o.created_at.slice(0, 10),
          total: money(o.total),
          estado: o.status === 'Revision' ? 'En revisión' : o.status,
          items: (o.items || []).length,
        })),
      };
    },
  },
  {
    def: {
      name: 'derivar_a_humano',
      description: 'Pasa la conversación a una persona del local y el bot deja de responder en este chat. Usala si el cliente pide hablar con alguien, tiene un reclamo, o pregunta algo que no podés resolver con tus herramientas ni con la info del negocio.',
      input_schema: {
        type: 'object',
        properties: {
          motivo: { type: 'string', description: 'Resumen corto de lo que necesita el cliente' },
        },
        required: ['motivo'],
        additionalProperties: false,
      },
    },
    async run({ motivo }, ctx){
      const until = new Date(Date.now() + HANDOFF_HOURS * 3600 * 1000).toISOString();
      await db.patch(`/bot_conversations?phone=eq.${encodeURIComponent(ctx.phone)}`, { paused_until: until });
      ctx.paused = true;
      const nombre = ctx.client?.full_name || ctx.profileName || 'Cliente';
      await notifyOwner(`🙋 ${nombre} (${ctx.phone}) necesita atención: ${motivo}\nwa.me/${ctx.waId}`);
      return { ok: true, aviso: 'Avisale al cliente que en breve le responde alguien del local.' };
    },
  },
];
