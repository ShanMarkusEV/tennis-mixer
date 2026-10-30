// Cloudflare Pages Function: POST /api/notify {sid}, with the host's own Supabase login as the bearer token.
// Sends an empty Web Push to every phone following that session by game PIN; each phone then fetches the
// session itself and shows "Round 3 · Court 2: you & Budi vs Citra & Dodi". The database only hands the
// phones to the session's host, so this can't be used to notify anyone else's players.
// Needs the VAPID_PRIVATE_KEY secret (Cloudflare Pages → Settings → Variables and Secrets).
import {json} from './_shared.js';

const SUPABASE_URL = 'https://tuaomjxnhlwhddiucigb.supabase.co';
const SUPABASE_KEY = 'sb_publishable_iYVtpH-Yb_ysG9liQ-NINw_h2DRDdNq';
export const VAPID_PUBLIC_KEY = 'BM_Saadl2okzD7CQlHWrmixmiTflfeKQ3khy5pAHa5ex3A11v26ukzVwBpLfhu_Jiu1ByiHcfOAy3e-Z1_CUSho';

const BATCH = 40;
const b64u = buf => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64u = s => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));

async function rpc(name, args, token) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {method: 'POST',
    headers: {apikey: SUPABASE_KEY, authorization: `Bearer ${token}`, 'content-type': 'application/json'}, body: JSON.stringify(args)});
  const body = await r.json().catch(() => null);
  if (!r.ok) throw new Error((body && body.message) || `Supabase returned ${r.status}`);
  return body;
}

// VAPID: a short-lived ES256 token for the push service's origin, signed with our private key.
async function vapidToken(aud, key) {
  const enc = o => b64u(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${enc({typ: 'JWT', alg: 'ES256'})}.${enc({aud, exp: Math.floor(Date.now() / 1000) + 3600, sub: 'mailto:shanmarkusdiablo@gmail.com'})}`;
  const sig = await crypto.subtle.sign({name: 'ECDSA', hash: 'SHA-256'}, key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${b64u(sig)}`;
}

export async function onRequestPost({request, env}) {
  if (!env.VAPID_PRIVATE_KEY) return json({error: 'Notifications are not set up yet'}, 503);
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const {sid, from = 0} = await request.json().catch(() => ({}));
  if (!token || !/^[0-9a-f-]{36}$/i.test(sid || '')) return json({error: 'Sign in and send a session id'}, 400);

  let all;
  try { all = await rpc('push_targets', {sid}, token); }
  catch (e) { return json({error: e.message}, 403); }
  // Cloudflare allows 50 outgoing requests per call: send in batches; the app calls again with `next`.
  const start = Math.max(0, parseInt(from, 10) || 0), targets = (all || []).slice(start, start + BATCH);
  const next = start + BATCH < (all || []).length ? start + BATCH : null;
  if (!targets.length) return json({sent: 0, gone: 0, next: null});

  const pub = unb64u(VAPID_PUBLIC_KEY);
  const key = await crypto.subtle.importKey('jwk', {kty: 'EC', crv: 'P-256', d: env.VAPID_PRIVATE_KEY,
    x: b64u(pub.slice(1, 33)), y: b64u(pub.slice(33, 65)), ext: true}, {name: 'ECDSA', namedCurve: 'P-256'}, false, ['sign']);
  const tokens = {}, gone = [];
  let sent = 0;
  await Promise.all(targets.map(async endpoint => {
    const aud = new URL(endpoint).origin;
    tokens[aud] = tokens[aud] || vapidToken(aud, key);
    try {
      const r = await fetch(endpoint, {method: 'POST', headers: {TTL: '3600', Urgency: 'high', 'content-length': '0',
        authorization: `vapid t=${await tokens[aud]}, k=${VAPID_PUBLIC_KEY}`}});
      if (r.status === 404 || r.status === 410) gone.push(endpoint);
      else if (r.ok) sent++;
    } catch (e) { /* one phone failing doesn't stop the rest */ }
  }));
  if (gone.length) await rpc('drop_push_targets', {sid, endpoints: gone}, token).catch(() => {});
  return json({sent, gone: gone.length, next: gone.length && next != null ? next - gone.length : next});
}
