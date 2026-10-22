// =====================================================================
// Stock pro (admin): costo, margen, stock mínimo, historial de movimientos
// e ingreso de mercadería leyendo la factura del proveedor con IA.
// Usa las tablas de supabase-migration-stock-pro.sql (product_admin,
// stock_movements, supplier_product_map) y las funciones stock_ingreso /
// stock_ajuste. Se apoya en lo que ya define index.html: state, render,
// adminFetch, adminSession, adminTryRefresh, toast, escapeHtml, normText.
// =====================================================================

const SP_MARGEN_BAJO = 20; // % de margen sobre el precio de venta
let spAdmin = {};          // product_id (api) -> {cost, cost_updated_at, min_stock, supplier}
let spEstado = 'sin_cargar'; // sin_cargar | cargando | ok | falta_sql
let spMapa = {};           // "PROVEEDOR|desc" -> {product_id, units_per_pack}

function spPesos(n) {
  return '$' + Number(n || 0).toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
function spFecha(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  const p = (x) => String(x).padStart(2, '0');
  return `${p(d.getDate())}/${p(d.getMonth() + 1)}/${d.getFullYear()} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
function spPrecioVenta(p) { return p.sellByWeight ? (Number(p.pricePerKg) || 0) : (Number(p.price) || 0); }
function spMargen(p) {
  const a = spAdmin[p._apiId]; const precio = spPrecioVenta(p);
  if (!a || !(a.cost > 0) || !(precio > 0)) return null;
  return (precio - a.cost) / precio * 100;
}
function spStockMinimo(p) {
  const a = spAdmin[p._apiId];
  return a && a.min_stock !== null && a.min_stock !== undefined ? a.min_stock : LOW_STOCK_THRESHOLD;
}

// Carga los datos internos (una vez por sesión de admin; se refresca al guardar).
async function spCargar(forzar) {
  if (!IS_ADMIN_APP || !adminSession) return;
  if (!forzar && (spEstado === 'cargando' || spEstado === 'ok' || spEstado === 'falta_sql')) return;
  spEstado = 'cargando';
  try {
    const filas = [];
    for (let off = 0; ; off += 1000) {
      const page = await adminFetch(`/product_admin?select=*&order=product_id.asc&limit=1000&offset=${off}`, 'GET');
      filas.push(...(page || []));
      if (!page || page.length < 1000) break;
    }
    spAdmin = {};
    filas.forEach((f) => { spAdmin[f.product_id] = { ...f, cost: f.cost !== null ? Number(f.cost) : null }; });
    spEstado = 'ok';
    render();
  } catch (e) {
    spEstado = /product_admin|does not exist|schema cache/i.test(e.message) ? 'falta_sql' : 'sin_cargar';
    console.warn('stock-pro:', e.message);
    if (spEstado === 'falta_sql') render();
  }
}

// Línea extra en la fila del producto (Admin › Productos).
function spFilaExtra(p) {
  spCargar();
  if (spEstado !== 'ok') return '';
  const a = spAdmin[p._apiId];
  const m = spMargen(p);
  const partes = [];
  if (a && a.cost > 0) partes.push(`Costo ${spPesos(a.cost)}`);
  if (m !== null) partes.push(`<span style="color:${m < SP_MARGEN_BAJO ? 'var(--danger)' : '#6dd39a'}; font-weight:700;">Margen ${m.toFixed(0)}%${m < SP_MARGEN_BAJO ? ' ⚠' : ''}</span>`);
  if (a && a.min_stock !== null && a.min_stock !== undefined) partes.push(`Mín. ${a.min_stock}`);
  if (a && a.supplier) partes.push(escapeHtml(a.supplier));
  return partes.length ? `<p style="font-size:11px; opacity:.85; margin-top:2px;">${partes.join(' · ')}</p>` : '';
}
function spBotonFicha(p) {
  return `<button class="icon-btn" title="Costo, margen, stock mínimo e historial" onclick="spAbrirFicha('${p.id}')">📊</button>`;
}
function spAvisoSql() {
  return spEstado === 'falta_sql'
    ? `<div style="margin:8px 0 0; padding:8px 10px; border:1px solid var(--warn); border-radius:10px; font-size:11.5px; color:var(--warn);">Para usar costo, márgenes e ingreso de mercadería falta correr <b>supabase-migration-stock-pro.sql</b> en Supabase.</div>`
    : '';
}

function spOverlay(id, html, ancho) {
  document.getElementById(id)?.remove();
  const ov = document.createElement('div');
  ov.className = 'modal-overlay';
  ov.id = id;
  ov.innerHTML = `<div class="modal-sheet" style="${ancho ? `max-width:${ancho}px;` : ''}"><div class="modal-handle"></div>${html}</div>`;
  ov.addEventListener('click', (e) => { if (e.target === ov) ov.remove(); });
  document.body.appendChild(ov);
  return ov;
}
const SP_INPUT = 'width:100%; padding:9px 10px; border-radius:10px; background:var(--glass); border:1px solid var(--glass-bd); color:var(--white); font-size:13px;';

// ── FICHA INTERNA DEL PRODUCTO ──
const SP_TIPOS = { venta: 'Venta / pedido', ingreso: 'Ingreso de mercadería', conteo: 'Conteo', ajuste: 'Ajuste', alta: 'Alta del producto', edicion: 'Edición / anulación' };

async function spAbrirFicha(id) {
  const p = state.products.find((x) => x.id === id);
  if (!p || !p._apiId) return;
  if (spEstado === 'falta_sql') { toast('Falta correr el SQL de stock en Supabase', 'err'); return; }
  const a = spAdmin[p._apiId] || {};
  spOverlay('sp-ficha', `
    <h3 class="modal-title">📊 ${escapeHtml(p.name)}</h3>
    <div style="display:grid; grid-template-columns:1fr 1fr; gap:10px;">
      <label style="font-size:11.5px; opacity:.8;">Costo por ${p.sellByWeight ? 'kg' : 'unidad'} ($)
        <input id="sp-f-costo" type="number" step="0.01" inputmode="decimal" value="${a.cost ?? ''}" style="${SP_INPUT}" oninput="spFichaMargen('${p.id}')"></label>
      <label style="font-size:11.5px; opacity:.8;">Precio de venta
        <input type="text" value="${spPesos(spPrecioVenta(p))}" disabled style="${SP_INPUT} opacity:.7;"></label>
      <label style="font-size:11.5px; opacity:.8;">Stock mínimo (avisa al llegar)
        <input id="sp-f-min" type="number" step="1" inputmode="numeric" value="${a.min_stock ?? ''}" placeholder="${LOW_STOCK_THRESHOLD} (general)" style="${SP_INPUT}"></label>
      <label style="font-size:11.5px; opacity:.8;">Proveedor habitual
        <input id="sp-f-prov" type="text" value="${escapeHtml(a.supplier || '')}" style="${SP_INPUT}"></label>
    </div>
    <div id="sp-f-margen" style="margin:10px 0; font-size:13px;"></div>
    ${a.cost_updated_at ? `<div style="font-size:11px; opacity:.6; margin-top:-6px; margin-bottom:10px;">Costo actualizado el ${spFecha(a.cost_updated_at)}</div>` : ''}
    <button class="btn-primary" style="width:100%;" onclick="spGuardarFicha('${p.id}')">Guardar</button>
    <h4 style="margin:18px 0 8px; font-size:14px;">Historial de stock <span style="opacity:.6; font-weight:400;">(stock actual: ${p.stock})</span></h4>
    <div id="sp-f-hist" style="font-size:12px; opacity:.8;">Cargando…</div>
  `);
  spFichaMargen(p.id);
  try {
    const movs = await adminFetch(`/stock_movements?product_id=eq.${p._apiId}&select=*&order=created_at.desc&limit=60`, 'GET');
    const el = document.getElementById('sp-f-hist');
    if (!el) return;
    el.innerHTML = !movs || !movs.length
      ? 'Todavía no hay movimientos registrados (se registran desde que se corrió el SQL de stock).'
      : `<table style="width:100%; border-collapse:collapse;">${movs.map((m) => `
          <tr style="border-bottom:1px solid var(--glass-bd);">
            <td style="padding:6px 4px; white-space:nowrap; opacity:.75;">${spFecha(m.created_at)}</td>
            <td style="padding:6px 4px;">${SP_TIPOS[m.kind] || escapeHtml(m.kind)}${m.ref ? ` · ${escapeHtml(m.ref)}` : ''}${m.note ? `<div style="opacity:.6;">${escapeHtml(m.note)}</div>` : ''}</td>
            <td style="padding:6px 4px; text-align:right; font-weight:700; color:${m.qty < 0 ? 'var(--danger)' : '#6dd39a'};">${m.qty > 0 ? '+' : ''}${m.qty}</td>
            <td style="padding:6px 4px; text-align:right; opacity:.75;">= ${m.stock_after ?? ''}</td>
          </tr>`).join('')}</table>`;
  } catch (e) {
    const el = document.getElementById('sp-f-hist');
    if (el) el.textContent = 'No se pudo cargar el historial: ' + e.message;
  }
}
function spFichaMargen(id) {
  const p = state.products.find((x) => x.id === id);
  const el = document.getElementById('sp-f-margen');
  if (!p || !el) return;
  const costo = parseFloat(document.getElementById('sp-f-costo').value) || 0;
  const precio = spPrecioVenta(p);
  if (!(costo > 0) || !(precio > 0)) { el.innerHTML = '<span style="opacity:.6;">Cargá el costo para ver el margen.</span>'; return; }
  const m = (precio - costo) / precio * 100;
  const sugerido = costo / (1 - SP_MARGEN_BAJO / 100);
  el.innerHTML = `Ganancia por ${p.sellByWeight ? 'kg' : 'unidad'}: <b>${spPesos(precio - costo)}</b> · Margen: <b style="color:${m < SP_MARGEN_BAJO ? 'var(--danger)' : '#6dd39a'};">${m.toFixed(1)}%</b>`
    + (m < SP_MARGEN_BAJO ? `<div style="color:var(--warn); font-size:12px; margin-top:4px;">⚠ Margen bajo: para ganar ${SP_MARGEN_BAJO}% el precio debería ser al menos ${spPesos(sugerido)}</div>` : '');
}
async function spGuardarFicha(id) {
  const p = state.products.find((x) => x.id === id);
  if (!p) return;
  const vCosto = document.getElementById('sp-f-costo').value.trim();
  const vMin = document.getElementById('sp-f-min').value.trim();
  const ant = spAdmin[p._apiId] || {};
  const costo = vCosto === '' ? null : Math.round((parseFloat(vCosto) || 0) * 100) / 100;
  const body = {
    product_id: p._apiId,
    cost: costo,
    cost_updated_at: costo !== ant.cost ? new Date().toISOString() : (ant.cost_updated_at || null),
    min_stock: vMin === '' ? null : Math.max(0, parseInt(vMin, 10) || 0),
    supplier: document.getElementById('sp-f-prov').value.trim() || null,
    updated_at: new Date().toISOString(),
  };
  try {
    const r = await adminFetch('/product_admin', 'POST', body, 'resolution=merge-duplicates,return=representation');
    spAdmin[p._apiId] = { ...body, ...(r && r[0] ? r[0] : {}), cost: costo };
    document.getElementById('sp-ficha')?.remove();
    toast('Guardado', 'ok');
    render();
  } catch (e) { toast('No se pudo guardar: ' + e.message, 'err'); }
}

// ── INGRESO DE MERCADERÍA ──
let spIng = null; // {proveedor, numero, letra, iva, filas:[{desc, codigo, cant, xBulto, costoBulto, productId, actualizarCosto, origen}], leyendo}

function spDescKey(s) { return normText(s).replace(/[^a-z0-9]+/g, ' ').trim(); }
function spTokens(s) {
  const VACIAS = new Set(['de', 'del', 'la', 'el', 'los', 'las', 'con', 'sin', 'y', 'x', 'en', 'por', 'un', 'una', 'gr', 'g', 'grs', 'cc', 'ml', 'kg', 'un', 'u', 'unid', 'und']);
  return spDescKey(s).split(' ').filter((t) => t.length > 1 && !VACIAS.has(t));
}
// Empareja un renglón con un producto: 1) lo aprendido de ese proveedor,
// 2) el código de barras, 3) parecido de nombre (solo como sugerencia).
function spEmparejar(fila, proveedor) {
  const m = spMapa[(proveedor || '').trim().toUpperCase() + '|' + spDescKey(fila.desc)];
  if (m) {
    const p = state.products.find((x) => x._apiId === m.product_id);
    if (p) return { productId: p.id, xBulto: Number(m.units_per_pack) || fila.xBulto, origen: 'aprendido' };
  }
  const cod = (fila.codigo || '').replace(/\D/g, '');
  if (cod.length >= 6) {
    const p = state.products.find((x) => x.barcode === cod);
    if (p) return { productId: p.id, origen: 'código' };
    const d = state.products.find((x) => x.displayBarcode === cod);
    if (d) return { productId: d.id, xBulto: d.displayQty || fila.xBulto, origen: 'código' };
  }
  const a = spTokens(fila.desc);
  if (!a.length) return null;
  let mejor = null, mejorS = 0;
  for (const p of state.products) {
    const b = spTokens(p.name);
    if (!b.length) continue;
    const comunes = a.filter((t) => b.includes(t)).length;
    if (!comunes) continue;
    const s = 2 * comunes / (a.length + b.length);
    if (s > mejorS) { mejorS = s; mejor = p; }
  }
  return mejor && mejorS >= 0.5 ? { productId: mejor.id, origen: 'sugerido' } : null;
}
function spEtiquetaProducto(p) { return `${p.name} · #${p._apiId}`; }
function spProveedoresConocidos() {
  return [...new Set(Object.values(spAdmin).map((a) => (a.supplier || '').trim()).filter(Boolean))].sort();
}

async function spAbrirIngreso() {
  if (spEstado === 'falta_sql') { toast('Falta correr el SQL de stock en Supabase', 'err'); return; }
  await spCargar();
  try {
    const filas = await adminFetch('/supplier_product_map?select=*&limit=5000', 'GET');
    spMapa = {};
    (filas || []).forEach((f) => { spMapa[f.proveedor_key + '|' + f.desc_key] = f; });
  } catch (e) { console.warn('supplier_product_map:', e.message); }
  spIng = spIng || { proveedor: '', numero: '', letra: '', iva: false, filas: [], leyendo: 0 };
  spOverlay('sp-ingreso', `
    <h3 class="modal-title">📥 Ingreso de mercadería</h3>
    <datalist id="sp-prods">${state.products.filter((p) => p._apiId).map((p) => `<option value="${escapeHtml(spEtiquetaProducto(p))}">`).join('')}</datalist>
    <datalist id="sp-provs">${spProveedoresConocidos().map((s) => `<option value="${escapeHtml(s)}">`).join('')}</datalist>
    <div style="display:grid; grid-template-columns:2fr 1fr; gap:10px;">
      <label style="font-size:11.5px; opacity:.8;">Proveedor<input id="sp-i-prov" list="sp-provs" value="${escapeHtml(spIng.proveedor)}" oninput="spIng.proveedor=this.value" style="${SP_INPUT}"></label>
      <label style="font-size:11.5px; opacity:.8;">N° de factura / remito<input id="sp-i-num" value="${escapeHtml(spIng.numero)}" oninput="spIng.numero=this.value" style="${SP_INPUT}"></label>
    </div>
    <div style="display:flex; gap:8px; margin:12px 0; flex-wrap:wrap;">
      <label class="btn-primary" style="flex:1; padding:11px; text-align:center; cursor:pointer;">📷 Leer factura con foto
        <input type="file" accept="image/*,application/pdf" multiple style="display:none;" onchange="spLeerFotos(this)"></label>
      <button class="btn-secondary" style="flex:0 0 auto; width:auto; padding:11px 14px;" onclick="spAgregarFila()">+ Renglón a mano</button>
    </div>
    <div id="sp-i-estado" style="font-size:12px; margin-bottom:8px;"></div>
    <label style="display:flex; align-items:center; gap:8px; font-size:12.5px; margin-bottom:10px;">
      <input type="checkbox" id="sp-i-iva" ${spIng.iva ? 'checked' : ''} onchange="spIng.iva=this.checked; spPintarFilas()" style="width:18px; height:18px;">
      Sumar IVA (21%) al costo <span style="opacity:.6;">— tildalo si los precios de la factura son sin IVA (factura A)</span>
    </label>
    <div id="sp-i-filas"></div>
    <div id="sp-i-pie" style="position:sticky; bottom:-20px; background:var(--navy2); padding:12px 0 4px; margin-top:8px;"></div>
  `, 920);
  spPintarFilas();
}

function spAgregarFila(datos) {
  const f = { desc: '', codigo: '', cant: 1, xBulto: 1, costoBulto: '', productId: '', actualizarCosto: true, origen: '', ...(datos || {}) };
  if (datos && !f.productId) {
    const m = spEmparejar(f, spIng.proveedor);
    if (m) Object.assign(f, m);
  }
  spIng.filas.push(f);
  if (!datos) spPintarFilas();
}
function spUnidades(f) { return Math.round((parseFloat(f.cant) || 0) * (parseInt(f.xBulto, 10) || 1)); }
function spCostoUnidad(f) {
  const c = (parseFloat(f.costoBulto) || 0) / (parseInt(f.xBulto, 10) || 1);
  return Math.round(c * (spIng.iva ? 1.21 : 1) * 100) / 100;
}

async function spLeerFotos(input) {
  const files = [...(input.files || [])];
  input.value = '';
  if (!files.length) return;
  const est = document.getElementById('sp-i-estado');
  for (let k = 0; k < files.length; k++) {
    const pref = files.length > 1 ? `Página ${k + 1} de ${files.length}: ` : '';
    try {
      est.innerHTML = `⏳ ${pref}leyendo la factura… puede tardar hasta un minuto.`;
      const r = await spLeerUna(files[k], (msg) => { est.innerHTML = pref + msg; });
      if (!r.legible) { est.innerHTML = `<span style="color:var(--warn);">⚠ ${pref}no pude leer esa foto. Probá con más luz y de frente.</span>`; continue; }
      if (!spIng.proveedor && r.proveedor) spIng.proveedor = r.proveedor;
      if (!spIng.numero && r.numero) spIng.numero = r.numero;
      if (r.letra === 'A') spIng.iva = true;
      (r.items || []).forEach((it) => {
        const costoBulto = it.subtotal > 0 && it.cantidad > 0 ? it.subtotal / it.cantidad : it.precioUnitario;
        spAgregarFila({ desc: it.descripcion, codigo: it.codigo, cant: it.cantidad, xBulto: it.unidadesPorBulto || 1, costoBulto: Math.round(costoBulto * 100) / 100 });
      });
      est.innerHTML = `<span style="color:#6dd39a;">✓ ${pref}${(r.items || []).length} renglón(es) leídos de ${escapeHtml(r.proveedor || 'la factura')}${r.letra ? ' (factura ' + r.letra + ')' : ''}. Revisá cada producto antes de aplicar.</span>`;
    } catch (e) {
      est.innerHTML = `<span style="color:var(--danger);">✗ ${pref}${escapeHtml(e.message)}</span>`;
    }
  }
  const prov = document.getElementById('sp-i-prov'); if (prov) prov.value = spIng.proveedor;
  const num = document.getElementById('sp-i-num'); if (num) num.value = spIng.numero;
  const iva = document.getElementById('sp-i-iva'); if (iva) iva.checked = spIng.iva;
  spPintarFilas();
}
function spAchicar(file) {
  return new Promise((resolve, reject) => {
    if (file.type === 'application/pdf') {
      if (file.size > 3 * 1024 * 1024) return reject(new Error('El PDF es muy pesado (máximo 3 MB)'));
      const fr = new FileReader();
      fr.onload = () => resolve({ data: String(fr.result).split(',')[1], mediaType: 'application/pdf' });
      fr.onerror = () => reject(new Error('No se pudo leer el archivo'));
      return fr.readAsDataURL(file);
    }
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const k = Math.min(1, 2200 / Math.max(img.width, img.height));
      const c = document.createElement('canvas');
      c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
      c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
      URL.revokeObjectURL(url);
      resolve({ data: c.toDataURL('image/jpeg', 0.88).split(',')[1], mediaType: 'image/jpeg' });
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('No se pudo abrir la imagen')); };
    img.src = url;
  });
}
// Igual que en la caja: si la IA gratuita está ocupada, reintenta sola.
async function spLeerUna(file, onEstado) {
  const archivo = await spAchicar(file);
  const ESPERAS = [3, 8, 15, 25];
  let renovado = false;
  for (let intento = 0; ; intento++) {
    const res = await fetch('/api/factura-foto', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ adminToken: adminSession && adminSession.access_token, detalle: true, data: archivo.data, mediaType: archivo.mediaType, proveedores: spProveedoresConocidos() }),
    }).catch(() => null);
    const r = res ? await res.json().catch(() => ({})) : {};
    if (res && res.ok) return r;
    if (res && res.status === 401 && !renovado && typeof adminTryRefresh === 'function' && await adminTryRefresh()) { renovado = true; intento--; continue; }
    const reintentable = !res || [429, 502, 503, 504].includes(res.status);
    if (!reintentable || intento >= ESPERAS.length) throw new Error(!res ? 'Sin conexión' : (r.error || 'Error ' + res.status));
    for (let s = ESPERAS[intento]; s > 0; s--) {
      onEstado(`<span style="color:var(--warn);">⏳ La IA está ocupada, reintento automático en ${s} s… no hace falta tocar nada.</span>`);
      await new Promise((ok) => setTimeout(ok, 1000));
    }
    onEstado('⏳ Leyendo de nuevo…');
  }
}

function spPintarFilas() {
  const cont = document.getElementById('sp-i-filas');
  if (!cont || !spIng) return;
  if (!spIng.filas.length) {
    cont.innerHTML = `<div style="text-align:center; opacity:.6; padding:24px 0; font-size:13px;">Leé la factura con una foto (podés elegir varias páginas) o agregá renglones a mano.</div>`;
    spPintarPie(); return;
  }
  const colores = { aprendido: '#6dd39a', código: '#6dd39a', sugerido: 'var(--warn)', manual: 'var(--white)' };
  cont.innerHTML = spIng.filas.map((f, i) => {
    const p = f.productId ? state.products.find((x) => x.id === f.productId) : null;
    return `<div style="border:1px solid ${p ? 'var(--glass-bd)' : 'var(--warn)'}; border-radius:12px; padding:10px; margin-bottom:8px;">
      <div style="display:flex; justify-content:space-between; gap:8px; font-size:12px; margin-bottom:6px;">
        <span><b>${escapeHtml(f.desc || 'Renglón ' + (i + 1))}</b>${f.codigo ? ` <span style="opacity:.6;">· ${escapeHtml(f.codigo)}</span>` : ''}</span>
        <button class="icon-btn" style="width:28px; height:28px; font-size:12px;" title="Quitar renglón" onclick="spIng.filas.splice(${i},1); spPintarFilas()">✕</button>
      </div>
      ${!f.desc ? `<input placeholder="Descripción (opcional)" value="" oninput="spIng.filas[${i}].desc=this.value" style="${SP_INPUT} margin-bottom:6px;">` : ''}
      <input list="sp-prods" placeholder="Elegí tu producto…" value="${p ? escapeHtml(spEtiquetaProducto(p)) : ''}" onchange="spElegirProducto(${i}, this.value)" style="${SP_INPUT} border-color:${p ? colores[f.origen] || 'var(--glass-bd)' : 'var(--warn)'};">
      <div style="font-size:10.5px; margin:3px 0 6px; color:${p ? colores[f.origen] || 'inherit' : 'var(--warn)'};">${p ? ({ aprendido: '✓ Emparejado como la última vez', código: '✓ Emparejado por código de barras', sugerido: '⚠ Sugerido por parecido de nombre: confirmá que sea este', manual: '✓ Elegido a mano' }[f.origen] || '') + ` · stock actual ${p.stock}` : '⚠ Elegí a qué producto tuyo corresponde (si no, este renglón no suma stock)'}</div>
      <div style="display:grid; grid-template-columns:repeat(4, minmax(0,1fr)); gap:6px; font-size:10.5px; opacity:.9;">
        <label>Cantidad<input type="number" step="any" value="${f.cant}" oninput="spIng.filas[${i}].cant=this.value; spPintarPie()" style="${SP_INPUT} padding:7px;"></label>
        <label>Unid. x bulto<input type="number" step="1" min="1" value="${f.xBulto}" oninput="spIng.filas[${i}].xBulto=this.value; spPintarPie()" style="${SP_INPUT} padding:7px;"></label>
        <label>Precio x ${parseInt(f.xBulto, 10) > 1 ? 'bulto' : 'unidad'}<input type="number" step="0.01" value="${f.costoBulto}" oninput="spIng.filas[${i}].costoBulto=this.value; spPintarPie()" style="${SP_INPUT} padding:7px;"></label>
        <label style="display:flex; flex-direction:column; justify-content:flex-end; gap:4px;"><span><input type="checkbox" ${f.actualizarCosto ? 'checked' : ''} onchange="spIng.filas[${i}].actualizarCosto=this.checked; spPintarPie()"> Actualizar costo</span></label>
      </div>
      <div id="sp-i-res-${i}" style="font-size:11.5px; margin-top:6px;"></div>
    </div>`;
  }).join('');
  spPintarPie();
}
function spElegirProducto(i, valor) {
  const m = String(valor).match(/#(\d+)\s*$/);
  const p = m ? state.products.find((x) => String(x._apiId) === m[1]) : null;
  spIng.filas[i].productId = p ? p.id : '';
  spIng.filas[i].origen = p ? 'manual' : '';
  if (!p && valor) toast('Elegí un producto de la lista', 'err');
  spPintarFilas();
}
function spPintarPie() {
  if (!spIng) return;
  let unidades = 0, total = 0, listas = 0, subaCosto = 0;
  spIng.filas.forEach((f, i) => {
    const p = f.productId ? state.products.find((x) => x.id === f.productId) : null;
    const u = spUnidades(f), cu = spCostoUnidad(f);
    total += cu * u;
    const el = document.getElementById('sp-i-res-' + i);
    if (p && u > 0) {
      listas++; unidades += u;
      const ant = spAdmin[p._apiId] && spAdmin[p._apiId].cost;
      const precio = spPrecioVenta(p);
      const m = precio > 0 && cu > 0 ? (precio - cu) / precio * 100 : null;
      if (ant && cu > ant * 1.005) subaCosto++;
      if (el) el.innerHTML = `Suma <b>+${u}</b> → stock ${p.stock + u} · Costo por unidad <b>${spPesos(cu)}</b>`
        + (ant ? ` <span style="opacity:.7;">(antes ${spPesos(ant)}${cu > ant * 1.005 ? ` <b style="color:var(--warn);">▲ ${((cu / ant - 1) * 100).toFixed(1)}%</b>` : ''})</span>` : '')
        + (m !== null ? ` · Margen <b style="color:${m < SP_MARGEN_BAJO ? 'var(--danger)' : '#6dd39a'};">${m.toFixed(0)}%</b>` : '');
    } else if (el) el.innerHTML = '';
  });
  const pie = document.getElementById('sp-i-pie');
  if (!pie) return;
  pie.innerHTML = `<div style="font-size:12px; margin-bottom:8px; opacity:.85;">${listas} producto(s) · +${unidades} unidades · total ${spPesos(total)}${subaCosto ? ` · <span style="color:var(--warn);">${subaCosto} subieron de costo</span>` : ''}</div>
    <div style="display:flex; gap:8px;">
      <button class="btn-secondary" style="flex:0 0 auto; width:auto; padding:12px 16px;" onclick="if(confirm('¿Descartar este ingreso?')){ spIng=null; document.getElementById('sp-ingreso')?.remove(); }">Descartar</button>
      <button class="btn-primary" style="flex:1;" ${listas ? '' : 'disabled'} onclick="spAplicarIngreso()">✓ Aplicar ingreso (${listas})</button>
    </div>`;
}
async function spAplicarIngreso() {
  const items = [];
  spIng.filas.forEach((f) => {
    const p = f.productId ? state.products.find((x) => x.id === f.productId) : null;
    const u = spUnidades(f);
    if (!p || !p._apiId || u <= 0) return;
    items.push({ product_id: p._apiId, qty: u, unit_cost: spCostoUnidad(f) || null, update_cost: !!f.actualizarCosto && spCostoUnidad(f) > 0,
      desc_key: f.desc ? spDescKey(f.desc) : '', units_per_pack: parseInt(f.xBulto, 10) || 1 });
  });
  const sinProducto = spIng.filas.filter((f) => !f.productId).length;
  if (!items.length) return;
  if (sinProducto && !confirm(`${sinProducto} renglón(es) no tienen producto elegido y no van a sumar stock. ¿Aplicar igual el resto?`)) return;
  try {
    await adminFetch('/rpc/stock_ingreso', 'POST', { p_items: items, p_proveedor: (spIng.proveedor || '').trim(), p_ref: (spIng.numero || '').trim(), p_note: '' });
    items.forEach((it) => {
      const p = state.products.find((x) => x._apiId === it.product_id);
      if (p) p.stock = (p.stock || 0) + it.qty;
      const a = spAdmin[it.product_id] = spAdmin[it.product_id] || { product_id: it.product_id };
      if (it.update_cost) { a.cost = it.unit_cost; a.cost_updated_at = new Date().toISOString(); }
      if (spIng.proveedor) a.supplier = spIng.proveedor.trim();
    });
    saveState();
    toast(`Ingreso aplicado: ${items.length} producto(s)`, 'ok');
    spIng = null;
    document.getElementById('sp-ingreso')?.remove();
    render();
  } catch (e) { toast('No se pudo aplicar el ingreso: ' + e.message, 'err'); }
}
