// 10nis service worker: lets the app be added to the home screen and open offline.
// Network first, so a new release is used as soon as it is online; the cache is only the offline fallback.
const CACHE = '10nis-offline';
const SHELL = ['/', '/icon.svg', '/icon-192.png', '/manifest.webmanifest'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE && k !== '10nis-follow').map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request, url = new URL(req.url);
  // Only this site's pages and files; the API, Supabase and CDNs go straight to the network.
  if (req.method !== 'GET' || url.origin !== location.origin || url.pathname.startsWith('/api/') || url.pathname.startsWith('/ad4min')) return;
  e.respondWith(fetch(req).then(res => {
    if (res.ok && res.type === 'basic') { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
    return res;
  }).catch(() => caches.match(req).then(hit => hit || (req.mode === 'navigate' ? caches.match('/') : Response.error()))));
});

// ---------- game PIN notifications ----------
// The push carries no data. The page saves which game and name this phone follows ({pin, me}); on a push
// we fetch that game and say where this player is now.
const SUPABASE_URL = 'https://tuaomjxnhlwhddiucigb.supabase.co';
const SUPABASE_KEY = 'sb_publishable_iYVtpH-Yb_ysG9liQ-NINw_h2DRDdNq';

async function followed() {
  const hit = await (await caches.open('10nis-follow')).match('/__follow');
  return hit ? hit.json() : null;
}
function message(g, me) {
  const name = id => ((g.players.find(p => p.id === id) || {}).name || '?');
  const team = ids => ids.filter(id => id !== me).map(name).join(' & ');
  const title = g.title || '10nis game';
  if (g.finished) return {title: `${title} is finished`, body: 'Final standings are in. Tap to see where you finished.'};
  const n = g.rounds.length, rd = g.rounds[n - 1];
  if (!rd) return {title, body: 'The game is about to start.'};
  const ci = (rd.matches || []).findIndex(m => (m.a || []).includes(me) || (m.b || []).includes(me));
  if (ci < 0) return {title: `Round ${n}: you sit out`, body: `${title}. Rest up, you're likely on next round.`};
  const m = rd.matches[ci], mineA = m.a.includes(me), mine = mineA ? m.a : m.b, theirs = mineA ? m.b : m.a;
  const partner = team(mine);
  return {title: `Round ${n} · Court ${ci + 1}: you're on!`,
    body: `${partner ? `You & ${partner}` : 'You'} vs ${team(theirs)}${g.venue ? ` · ${g.venue}` : ''}`};
}
self.addEventListener('push', e => {
  e.waitUntil((async () => {
    const f = await followed().catch(() => null);
    let msg = {title: '10nis', body: 'Your game has an update.'}, pin = f && f.pin;
    if (f && f.pin && f.me) {
      try {
        const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/pin_session`, {method: 'POST',
          headers: {apikey: SUPABASE_KEY, 'content-type': 'application/json'}, body: JSON.stringify({p: f.pin})});
        const g = await r.json();
        if (g && g.rounds) msg = message(g, f.me);
      } catch (err) {}
    }
    await self.registration.showNotification(msg.title, {body: msg.body, icon: '/icon-192.png', badge: '/icon-192.png',
      tag: '10nis-' + (pin || 'game'), renotify: true, data: {url: pin ? '/j/' + pin : '/'}});
  })());
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/';
  e.waitUntil(self.clients.matchAll({type: 'window', includeUncontrolled: true}).then(list => {
    const w = list.find(c => new URL(c.url).origin === location.origin);
    if (w) { w.postMessage({open: url}); return w.focus(); }
    return self.clients.openWindow(url);
  }));
});
