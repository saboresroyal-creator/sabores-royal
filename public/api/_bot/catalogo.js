// Catálogo y precios del lado del servidor. Replica las reglas de
// public/index.html (effectivePrice, effectivePriceForWeight,
// cartItemLineTotal) para que el bot cobre exactamente lo mismo que la web.
// Los precios SIEMPRE se calculan acá: nunca se usa un precio que haya
// escrito el modelo.

import { db, todayAR } from './db.js';

export const MIN_WHOLESALE_ORDER = 50000;

export function money(n){
  return '$' + Math.round(Number(n) || 0).toLocaleString('es-AR');
}

export function activePromo(p){
  if(!p || !p.promo_price) return null;
  if(p.super_offer) return Number(p.promo_price);
  if(!p.promo_until) return null;
  return p.promo_until >= todayAR() ? Number(p.promo_price) : null;
}

// Prioridad: mayorista > promo > precio normal (igual que la web).
export function unitPrice(p, wholesale){
  if(wholesale) return Number(p.wholesale_price) || Number(p.price) || 0;
  const promo = activePromo(p);
  return promo !== null ? promo : Number(p.price) || 0;
}

export function kgPrice(p, wholesale){
  if(wholesale) return Number(p.wholesale_price_per_kg) || Number(p.price_per_kg) || 0;
  const promo = activePromo(p);
  return promo !== null ? promo : Number(p.price_per_kg) || 0;
}

export function lineTotal(p, { qty, grams }, wholesale){
  if(p.sell_by_weight && grams) return (kgPrice(p, wholesale) / 1000) * grams;
  const base = unitPrice(p, wholesale);
  if(!wholesale && p.display_qty && p.display_discount && qty >= p.display_qty){
    return Math.round(base * (1 - p.display_discount / 100)) * qty;
  }
  return base * qty;
}

// PostgREST: los valores de filtro no pueden traer comas ni paréntesis.
function cleanWord(w){
  return w.replace(/[^\p{L}\p{N}]/gu, '');
}

const STOPWORDS = new Set(['de', 'del', 'la', 'las', 'el', 'los', 'un', 'una', 'unos', 'unas', 'con', 'para', 'por', 'que', 'hay', 'tienen', 'tenes', 'tenés', 'algo', 'algun', 'algún', 'alguna', 'producto', 'productos', 'apto', 'aptos', 'y', 'o']);

// Busca por nombre / categoría / subcategoría, todas las palabras tienen
// que aparecer. "sin tacc" / "sin azúcar" se buscan por la marca del
// producto (no suelen estar en el nombre). Si no encuentra nada, reintenta
// en singular y después ignorando tildes (cada vocal pasa a ser comodín).
export async function searchProducts(query, { includeHidden = false, limit = 20 } = {}){
  let q = String(query || '').toLowerCase();
  const flags = [];
  if(/sin\s+tacc|celiac|cel[ií]ac|gluten/.test(q)){ flags.push('sin_tacc=eq.true'); q = q.replace(/sin\s+tacc|apto\s+cel[ií]acos?|cel[ií]ac[oa]s?|sin\s+gluten|gluten/g, ' '); }
  if(/sin\s+az[uú]car|diab[eé]tic/.test(q)){ flags.push('sin_azucar=eq.true'); q = q.replace(/sin\s+az[uú]car|para\s+diab[eé]tic[oa]s?|diab[eé]tic[oa]s?/g, ' '); }
  const words = q.split(/\s+/).map(cleanWord).filter(w => w.length >= 2 && !STOPWORDS.has(w)).slice(0, 5);
  if(!words.length && !flags.length) return [];
  const run = async (toPattern) => {
    const conds = words.map(w => {
      const pat = toPattern(w);
      return `or(name.ilike.*${pat}*,cat.ilike.*${pat}*,sub.ilike.*${pat}*)`;
    });
    let path = `/products?select=*&order=name.asc&limit=${limit + 1}`;
    if(conds.length) path += `&and=(${conds.join(',')})`;
    for(const f of flags) path += '&' + f;
    if(!includeHidden) path += '&hidden=eq.false';
    return db.get(path);
  };
  const singular = w => w.length > 4 ? w.replace(/(es|s)$/, '') : w;
  let rows = await run(w => w);
  if(!rows.length) rows = await run(singular);
  if(!rows.length) rows = await run(w => singular(w).replace(/[aeiouáéíóúü]/g, '_'));
  return rows;
}

export async function getProductsByIds(ids){
  const clean = [...new Set(ids.map(Number).filter(Number.isFinite))];
  if(!clean.length) return [];
  return db.get(`/products?select=*&id=in.(${clean.join(',')})`);
}

// Vista de producto para un cliente: sin costos ni datos internos, y el
// stock como disponibilidad (no el número exacto salvo que queden pocos).
export function productForCustomer(p, wholesale){
  const out = { id: p.id, nombre: p.name, categoria: [p.cat, p.sub].filter(Boolean).join(' / ') };
  if(p.sell_by_weight){
    out.precio_por_kg = money(kgPrice(p, wholesale));
    if(p.min_grams) out.minimo_gramos = p.min_grams;
  }else{
    out.precio_unitario = money(unitPrice(p, wholesale));
    if(!wholesale && activePromo(p) !== null) out.oferta = `en oferta (antes ${money(p.price)})`;
    if(!wholesale && p.display_qty && p.display_discount){
      out.precio_por_caja = `llevando ${p.display_qty} unidades: ${money(Math.round(unitPrice(p, false) * (1 - p.display_discount / 100)))} c/u`;
    }else if(p.display_qty){
      out.unidades_por_caja = p.display_qty;
    }
  }
  if(p.description) out.descripcion = p.description.slice(0, 200);
  if(p.sin_tacc) out.sin_tacc = true;
  if(p.sin_azucar) out.sin_azucar = true;
  if(!p.sell_by_weight){
    const s = Number(p.stock) || 0;
    out.disponibilidad = s <= 0 ? 'sin stock' : s <= 5 ? `quedan ${s}` : 'disponible';
  }
  return out;
}
