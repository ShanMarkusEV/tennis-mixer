// Cloudflare Pages Function: GET /api/import?url=<Kuyy or Reclub activity link>
// Returns {source, title, players: [{name, status: 'confirmed' | 'waitlisted', photo}]}.
// Reclub pages can't be read from the browser (no CORS), so the app asks this function instead.
// Only Kuyy and Reclub hosts are fetched, so this is not an open proxy.

const UA = 'Mozilla/5.0 (compatible; TennisMixer/1.0; +https://10nis.win)';
const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'}
});
const isHost = (host, domain) => host === domain || host.endsWith('.' + domain);

export async function onRequestGet({request}) {
  let link;
  try { link = new URL(new URL(request.url).searchParams.get('url') || ''); }
  catch { return json({error: 'Paste a full activity link, starting with https://'}, 400); }
  try {
    if (isHost(link.hostname, 'kuyy.id') || isHost(link.hostname, 'kuyy.app')) return json(await kuyy(link));
    if (isHost(link.hostname, 'reclub.co')) return json(await reclub(link));
    return json({error: 'Only Kuyy and Reclub links are supported'}, 400);
  } catch (e) {
    return json({error: e.message || 'Could not read that activity'}, 502);
  }
}

// ---------- Kuyy ----------
// Activity pages are kuyy.id/[lang/]activities/<uuid>; members come from Kuyy's public API.
// A booking for several spots lists each ticket's name in checkin_status.
async function kuyy(link) {
  const id = (link.pathname.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i) || [])[0];
  if (!id) throw new Error('That Kuyy link has no activity ID');
  const get = async path => {
    const r = await fetch('https://kuyy.app/api' + path, {headers: {'user-agent': UA, accept: 'application/json'}});
    if (r.status === 404) throw new Error('Kuyy activity not found');
    if (!r.ok) throw new Error(`Kuyy returned ${r.status}`);
    return r.json();
  };
  const [event, members] = await Promise.all([
    get(`/public/events/${id}`).catch(() => ({})),
    get(`/events/${id}/members?limit=500`)
  ]);
  const players = [];
  for (const m of members.data || []) {
    // The host is usually the organiser's account, not a player.
    if (m.user_role === 'host') continue;
    const status = m.user_status === 'going' ? 'confirmed' : /wait/.test(m.user_status || '') ? 'waitlisted' : null;
    if (!status) continue;
    const tickets = (m.checkin_status || []).filter(t => t.status !== 'cancelled' && t.name);
    // The account photo belongs to the booker only, not their guests.
    const photo = m.image_url || null;
    if (tickets.length) tickets.forEach(t => players.push({name: t.name, status, photo: t.name === m.name ? photo : null}));
    else for (let i = 0; i < (m.quantity || 1); i++) players.push({name: i ? `${m.name} +${i}` : m.name, status, photo: i ? null : photo});
  }
  const ev = event.data || event;
  return {source: 'Kuyy', title: ev.title || ev.name || '', players};
}

// ---------- Reclub ----------
// Meet pages (reclub.co/m/<code>) are server-rendered by Nuxt; the participant list and a
// usersMap of names are in the __NUXT_DATA__ payload (devalue format: a flat array of indices).
const RECLUB_STATUS = {1: 'confirmed', 2: 'waitlisted'}; // 4 = requested, 5 = maybe, 0 = host only

async function reclub(link) {
  const r = await fetch(link.toString(), {headers: {'user-agent': UA, accept: 'text/html'}});
  if (!isHost(new URL(r.url).hostname, 'reclub.co')) throw new Error('Unexpected redirect');
  if (r.status === 404) throw new Error('Reclub activity not found');
  if (!r.ok) throw new Error(`Reclub returned ${r.status}`);
  const html = await r.text();
  const raw = (html.match(/<script[^>]*id="__NUXT_DATA__"[^>]*>([\s\S]*?)<\/script>/) || [])[1];
  if (!raw) throw new Error('No activity found at that Reclub link');
  const data = devalue(JSON.parse(raw));
  const entry = Object.entries((data && data.data) || {}).find(([k, v]) => k.startsWith('meet-') && v && v.meet);
  if (!entry) throw new Error('No activity found at that Reclub link');
  const {meet, usersMap = {}} = entry[1];
  const players = [];
  for (const p of meet.participants || []) {
    const status = RECLUB_STATUS[p.status], user = usersMap[p.referenceId];
    // Users without a photo get a generated initials image; skip it so the app's own avatar shows.
    const photo = user && user.imageUrl && !user.imageUrl.includes('/default-avatars/') ? user.imageUrl : null;
    if (status && user && user.name) players.push({name: user.name.trim(), status, photo});
  }
  return {source: 'Reclub', title: (meet.name || '').trim(), players};
}

function devalue(arr) {
  const cache = new Map();
  const wrappers = new Set(['Reactive', 'ShallowReactive', 'Ref', 'ShallowRef', 'EmptyRef', 'EmptyShallowRef']);
  const get = i => {
    if (typeof i !== 'number' || i < 0) return undefined;
    if (cache.has(i)) return cache.get(i);
    const v = arr[i];
    let out = v;
    if (Array.isArray(v)) {
      if (typeof v[0] === 'string') out = wrappers.has(v[0]) ? get(v[1]) : v[0] === 'Date' ? v[1] : undefined;
      else { out = []; cache.set(i, out); v.forEach(x => out.push(get(x))); return out; }
    } else if (v && typeof v === 'object') {
      out = {}; cache.set(i, out);
      for (const k in v) out[k] = get(v[k]);
      return out;
    }
    cache.set(i, out);
    return out;
  };
  return get(0);
}
