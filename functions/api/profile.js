// Cloudflare Pages Function: GET /api/profile?url=<Kuyy or Reclub player profile link>
// Returns {source, id, username, name, photo, counts, history: [{key, date, level_min, level_max, title}]}.
// Used when a 10nis user links their own Kuyy/Reclub profile: the history becomes level evidence.
//   Kuyy:   kuyy.id/[lang/]users/<uuid>  → public user record + past events (newest 100, tennis only)
//   Reclub: reclub.co/players/@<username> → public player page (activity counts; no list of past meets)

import {UA, json, isHost, levelFromTitle, activityKey, wibDate} from './_shared.js';
import {devalue} from './import.js';

export async function onRequestGet({request}) {
  let link;
  try { link = new URL(new URL(request.url).searchParams.get('url') || ''); }
  catch { return json({error: 'Paste your full profile link, starting with https://'}, 400); }
  try {
    if (isHost(link.hostname, 'kuyy.id') || isHost(link.hostname, 'kuyy.app')) return json(await kuyy(link));
    if (isHost(link.hostname, 'reclub.co')) return json(await reclub(link));
    return json({error: 'Only Kuyy and Reclub profile links are supported'}, 400);
  } catch (e) {
    return json({error: e.message || 'Could not read that profile'}, 502);
  }
}

async function kuyy(link) {
  const id = (link.pathname.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i) || [])[0];
  if (!id || !/\/users\//.test(link.pathname)) throw new Error('Open your Kuyy profile and copy its link (kuyy.id/users/…)');
  const get = async path => {
    const r = await fetch('https://kuyy.app/api' + path, {headers: {'user-agent': UA, accept: 'application/json'}});
    if (r.status === 404) throw new Error('Kuyy profile not found');
    if (!r.ok) throw new Error(`Kuyy returned ${r.status}`);
    return r.json();
  };
  const [u, past] = await Promise.all([get(`/users/${id}`), get(`/events?user_id=${id}&when=past&limit=100`)]);
  const history = [];
  for (const e of past.data || []) {
    if (e.category && e.category !== 'tennis') continue;
    const start = Date.parse(e.start_timestamp || '');
    const key = activityKey(start, e.location_label || e.location);
    if (!key) continue;
    const lvl = levelFromTitle(e.name);
    history.push({key, date: wibDate(start), level_min: lvl ? lvl.min : null, level_max: lvl ? lvl.max : null, title: (e.name || '').trim().slice(0, 120)});
  }
  return {source: 'kuyy', id: u.id || id, username: u.username || null, name: u.name || u.username || 'Kuyy player',
    photo: u.image_url || null, counts: {joined: past.count ?? history.length}, history};
}

async function reclub(link) {
  const username = (link.pathname.match(/\/(?:players\/)?@([\w.-]+)/) || [])[1];
  if (!username) throw new Error('Open your Reclub profile and copy its link (reclub.co/players/@…)');
  const r = await fetch(`https://reclub.co/players/@${encodeURIComponent(username)}`, {headers: {'user-agent': UA, accept: 'text/html'}});
  if (r.status === 404) throw new Error('Reclub profile not found');
  if (!r.ok) throw new Error(`Reclub returned ${r.status}`);
  const raw = ((await r.text()).match(/<script[^>]*id="__NUXT_DATA__"[^>]*>([\s\S]*?)<\/script>/) || [])[1];
  const data = raw && devalue(JSON.parse(raw));
  const p = data && data.data && Object.entries(data.data).find(([k]) => k.startsWith('player-'));
  if (!p || !p[1] || !p[1].userId) throw new Error('Reclub profile not found');
  const pl = p[1], tennis = (pl.sports || []).find(s => s.sportId === 1) || {};
  const photo = pl.imageUrl && !pl.imageUrl.includes('/default-avatars/') ? pl.imageUrl : null;
  return {source: 'reclub', id: String(pl.userId), username: pl.username || username, name: pl.name || username, photo,
    counts: {joined: tennis.numActivities ?? (pl.counts || {}).joined ?? 0, matches: tennis.numMatches ?? 0, noShows: (pl.counts || {}).noShows ?? 0},
    history: []};
}
