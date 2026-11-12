// Service worker (CORE-9): caches the application shell only, so the app opens offline and says it is offline. API
// responses, the catalog and the session are never cached (every figure shown comes from the server, live).
const VERSION = 'bnx-shell-0.4.0-core9';
const SHELL = ['/app/', '/app/index.html', '/app/app.css', '/app/js/main.js', '/app/js/api.js', '/app/js/i18n.js', '/app/js/render.js',
  '/app/i18n/en.json', '/app/i18n/zh-Hans.json', '/app/menu.json', '/app/manifest.webmanifest', '/app/icon.svg'];

self.addEventListener('install', (e) => { e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== self.location.origin || !u.pathname.startsWith('/app/') || u.pathname === '/app/config.json') return;
  // network first (a deploy shows at once); the cached shell only when the network fails
  e.respondWith(fetch(e.request).then((r) => {
    if (r.ok) { const copy = r.clone(); caches.open(VERSION).then((c) => c.put(e.request, copy)); }
    return r;
  }).catch(() => caches.match(e.request, { ignoreSearch: true }).then((m) => m || caches.match('/app/index.html'))));
});
