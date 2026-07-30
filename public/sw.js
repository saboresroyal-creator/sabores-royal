const CACHE = 'sabores-royal-v12';

self.addEventListener('install', e => {
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  if (e.request.url.includes('/api/')) return;
  // Datos en vivo de Supabase: nunca servir desde caché (ni siquiera si falla la red),
  // para no mostrar productos/contenido desactualizado en conexiones móviles inestables.
  if (e.request.url.includes('supabase.co')) return;

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
