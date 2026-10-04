// Hortlog service worker: lets the app open offline, and shows push notifications.
// Bump CACHE only if a phone keeps showing an old version.
const CACHE = 'hortlog-v19';
const SHELL = ['./', 'index.html', 'manifest.webmanifest', 'icon.svg'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
  );
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  if (u.hostname.endsWith('supabase.co')) return; // never cache account or data calls
  const ok = u.origin === location.origin || /cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com|fonts\.(googleapis|gstatic)\.com/.test(u.hostname);
  if (!ok) return;
  e.respondWith(
    caches.match(r).then(hit => {
      const net = fetch(r).then(res => {
        if (res && res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(r, copy)); }
        return res;
      }).catch(() => hit);
      return hit || net;
    })
  );
});

// Notifications sent by the server
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: 'Hortlog', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Hortlog', {
    body: d.body || '',
    icon: 'icon-192.png',
    badge: 'badge-96.png',
    vibrate: [200, 100, 200],
    silent: false,
    renotify: !!d.tag,
    tag: d.tag,
    data: { url: d.url || './' }
  }));
});

// Tapping a notification opens the app
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || './';
  e.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
      for (const c of cs) { if ('focus' in c) { c.focus(); return; } }
      return clients.openWindow(url);
    })
  );
});
