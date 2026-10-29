// Cloudflare Pages Function: GET /api/import?url=<Kuyy or Reclub activity link>
// Returns {source, title, players: [{name, status: 'confirmed' | 'waitlisted', photo, ext}], activity}.
//   ext      = {source, id, username}: that platform's identity for the person, when they have an account.
//   activity = {source, key, date, level_min, level_max}: when the activity happened and the level it was
//              advertised at (app scale 1–10), used as evidence for everyone who played.
// Reclub pages can't be read from the browser (no CORS), so the app asks this function instead.
// Only Kuyy and Reclub hosts are fetched, so this is not an open proxy.

import {UA, json, isHost, levelFromTitle, reclubLevel, activityKey, wibDate} from './_shared.js';

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
    // The account photo and identity belong to the booker only, not their guests.
    const photo = m.image_url || null;
    const ext = m.id ? {source: 'kuyy', id: m.id, username: m.username || null} : null;
    if (tickets.length) tickets.forEach(t => {
      const self = t.name === m.name;
      players.push({name: t.name, status, photo: self ? photo : null, ext: self ? ext : null});
    });
    else for (let i = 0; i < (m.quantity || 1); i++)
      players.push({name: i ? `${m.name} +${i}` : m.name, status, photo: i ? null : photo, ext: i ? null : ext});
  }
  const ev = event.data || event;
  const title = ev.title || ev.name || '';
  const start = Date.parse(ev.start_timestamp || '');
  const level = levelFromTitle(title);
  const activity = start ? {source: 'kuyy', key: activityKey(start, ev.location_label || ev.location), date: wibDate(start),
    level_min: level ? level.min : null, level_max: level ? level.max : null} : null;
  return {source: 'Kuyy', title, players, activity};
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
    // Players the host added by hand have no Reclub account: their name is in externalReference instead.
    const status = RECLUB_STATUS[p.status], user = usersMap[p.referenceId] || {};
    const name = user.name || (p.externalReference && p.externalReference.name);
    // Users without a photo get a generated initials image; skip it so the app's own avatar shows.
    const photo = user.imageUrl && !user.imageUrl.includes('/default-avatars/') ? user.imageUrl : null;
    const ext = user.userId ? {source: 'reclub', id: String(user.userId), username: user.username || null} : null;
    if (status && name) players.push({name: String(name).trim(), status, photo, ext});
  }
  const title = (meet.name || '').trim();
  const start = meet.startDatetime ? meet.startDatetime * 1000 : NaN;
  // Reclub's structured level range when the host set one, else whatever the title says.
  const lvl = meet.minSportLevelValue != null || meet.maxSportLevelValue != null
    ? {min: reclubLevel(meet.minSportLevelValue ?? meet.maxSportLevelValue), max: reclubLevel(meet.maxSportLevelValue ?? meet.minSportLevelValue)}
    : levelFromTitle(title);
  const activity = start ? {source: 'reclub', key: activityKey(start, meet.venue && meet.venue.name), date: wibDate(start),
    level_min: lvl ? lvl.min : null, level_max: lvl ? lvl.max : null} : null;
  return {source: 'Reclub', title, players, activity};
}

export function devalue(arr) {
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
