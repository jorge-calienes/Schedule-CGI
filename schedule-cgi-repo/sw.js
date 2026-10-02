// Minimal service worker — exists only to make the app installable as a
// PWA (a fetch handler is one of the browser's installability checks) and
// to give a same-origin network blip a cached fallback instead of a blank
// error page. It deliberately does NOT try to make this app work offline:
// the board is live Supabase data, and anything stale here would be worse
// than an honest "you're offline" failure.
//
// Bump CACHE_NAME to force every client to drop the old cache on the next
// visit (the activate handler below deletes anything not matching it).
const CACHE_NAME = 'rotation-control-shell-v1';
const SHELL_FILES = [
  '/',
  '/index.html',
  '/manifest.json',
  '/lib/supabaseClient.js',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;

  // Only ever touch same-origin GET requests for the static shell above —
  // never the API routes (/api/...), never cross-origin calls to Supabase
  // (REST, auth, realtime websockets), and never anything non-GET. Those
  // all pass straight through untouched, exactly as if this file didn't
  // exist, since index.html already sends its own no-cache headers and
  // this app's data has to be live, not cached.
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/api/')) return;
  if (!SHELL_FILES.includes(url.pathname) && url.pathname !== '/') return;

  // Network-first: always prefer the live deploy (matching index.html's
  // own no-cache, must-revalidate policy) and only fall back to whatever
  // was last cached if the network request itself fails outright — a
  // dropped connection, not a slow one, since this doesn't race a timeout.
  event.respondWith(
    fetch(req)
      .then((res) => {
        const copy = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(req).then((cached) => cached || Response.error()))
  );
});
