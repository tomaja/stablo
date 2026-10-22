// Service worker: shows editors' notifications about new suggestions (sent by functions/api/notify.js).
// It caches nothing; the pages always load fresh.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Novi predlog', {
    body: d.body || '', tag: d.tag, renotify: !!d.tag, icon: 'icon-192.png', badge: 'badge-72.png',
    data: { url: d.url || './#review' }
  }));
});

// a click opens the review queue (the main page sends phones on to the phone view's queue)
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './#review', self.registration.scope).href;
  e.waitUntil(self.clients.openWindow(url));
});
