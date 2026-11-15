const CACHE_NAME = 'multisearch-v3';
const ASSETS = [
  '/',
  '/index.html',
  '/favicon.svg',
  '/icon-192.png',
  '/icon-512.png',
  '/manifest.json',
  'https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css',
  'https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.1.1/css/all.min.css',
  'https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

function putInCache(request, response) {
  if (response && response.status === 200) {
    const clone = response.clone();
    caches.open(CACHE_NAME).then(cache => cache.put(request, clone));
  }
  return response;
}

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const sameOrigin = new URL(req.url).origin === self.location.origin;

  if (sameOrigin) {
    // Egna filer: hämta från nätet först så att uppdateringar syns direkt,
    // och använd cachen bara när du är offline.
    event.respondWith(
      fetch(req)
        .then(res => putInCache(req, res))
        .catch(() => caches.match(req).then(c => c || caches.match('/index.html')))
    );
  } else {
    // CDN-filer har fast version – cachen räcker.
    event.respondWith(
      caches.match(req).then(cached => cached || fetch(req).then(res => putInCache(req, res)))
    );
  }
});

// Klick på en påminnelse öppnar sidan
self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window' }).then(list =>
      list.length ? list[0].focus() : self.clients.openWindow('/')
    )
  );
});
