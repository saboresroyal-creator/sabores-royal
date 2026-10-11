const CACHE = 'sabores-royal-v13';
// Fotos de productos (Supabase Storage). Cada foto se sube con un nombre
// único que nunca se reutiliza (prefijo + timestamp), así que una vez
// bajada no cambia nunca: se guarda en el celular y no se vuelve a pedir.
// Bajar las fotos una y otra vez agotó la cuota de transferencia del plan
// gratuito de Supabase. Este caché tiene nombre propio para que no se
// borre cuando se actualiza la app.
const PHOTO_CACHE = 'sabores-royal-fotos';
const PHOTO_CACHE_MAX = 1500;
const PHOTO_PATH = '/storage/v1/object/public/';

self.addEventListener('install', e => {
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== PHOTO_CACHE).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

async function trimPhotoCache(cache){
  const keys = await cache.keys();
  if (keys.length <= PHOTO_CACHE_MAX) return;
  await Promise.all(keys.slice(0, keys.length - PHOTO_CACHE_MAX).map(k => cache.delete(k)));
}

async function photoFromCache(request){
  const cache = await caches.open(PHOTO_CACHE);
  const url = request.url;
  const hit = await cache.match(url);
  if (hit) return hit;
  // Un <img> pide la foto sin CORS y la respuesta llega "opaca": no se
  // puede saber si es la foto o un error (ej: Supabase bloqueado), y
  // guardarla podría dejar una foto rota para siempre. Por eso se pide en
  // modo CORS (Storage lo permite) y solo se guarda si llegó bien.
  let res;
  try {
    res = await fetch(url, { mode: 'cors', credentials: 'omit' });
  } catch (e) {
    return fetch(request);
  }
  if (res.ok) {
    cache.put(url, res.clone()).then(() => trimPhotoCache(cache)).catch(() => {});
  }
  return res;
}

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  if (e.request.url.includes('/api/')) return;
  if (e.request.url.includes('supabase.co')) {
    if (e.request.url.includes(PHOTO_PATH)) e.respondWith(photoFromCache(e.request));
    // El resto de Supabase son datos en vivo: nunca desde caché (ni
    // siquiera si falla la red), para no mostrar productos/contenido
    // desactualizado en conexiones móviles inestables.
    return;
  }

  // HTML siempre desde red, nunca caché
  if (e.request.mode === 'navigate' || e.request.url.endsWith('.html')) {
    e.respondWith(fetch(e.request));
    return;
  }

  // Resto: network-first con fallback a caché
  e.respondWith(
    fetch(e.request).then(res => {
      if (res.ok) {
        const clone = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, clone));
      }
      return res;
    }).catch(() => caches.match(e.request))
  );
});
