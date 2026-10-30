// Cloudflare Pages Function: GET /api/social/callback — Threads sends the admin back here after approving.
// Checks the one-time state, swaps the code for a 1-hour token and that for a 60-day token (with the App
// Secret, which never leaves Cloudflare), stores it, and returns to /ad4min.
// Needs THREADS_APP_ID, THREADS_APP_SECRET and SOCIAL_CRON_SECRET.
import {rpc} from './_lib.js';

const back = (request, result) => Response.redirect(new URL(`/ad4min?threads=${encodeURIComponent(result)}`, request.url).toString(), 302);

export async function onRequestGet({request, env}) {
  const url = new URL(request.url), p = url.searchParams;
  if (p.get('error')) return back(request, p.get('error_description') || p.get('error'));
  if (!env.THREADS_APP_ID || !env.THREADS_APP_SECRET || !env.SOCIAL_CRON_SECRET) return back(request, 'Threads app secrets are not set in Cloudflare');
  const secret = env.SOCIAL_CRON_SECRET;
  try {
    if (!(await rpc('social_cron_oauth_take', {secret, st: p.get('state') || ''}))) return back(request, 'This sign-in link expired. Try Connect Threads again');
    const graph = env.THREADS_GRAPH || 'https://graph.threads.com';
    const call = async (path, init) => {
      const r = await fetch(graph + path, init);
      const d = await r.json().catch(() => ({}));
      if (!r.ok || d.error) throw new Error((d.error && (d.error.message || d.error)) || d.error_message || `Threads returned ${r.status}`);
      return d;
    };
    const code = (p.get('code') || '').replace(/#_$/, '');
    const short = await call('/oauth/access_token', {method: 'POST', body: new URLSearchParams({client_id: env.THREADS_APP_ID,
      client_secret: env.THREADS_APP_SECRET, grant_type: 'authorization_code', code,
      redirect_uri: new URL('/api/social/callback', request.url).toString()})});
    const long = await call('/access_token?' + new URLSearchParams({grant_type: 'th_exchange_token',
      client_secret: env.THREADS_APP_SECRET, access_token: short.access_token}));
    const me = await call('/v1.0/me?' + new URLSearchParams({fields: 'id,username', access_token: long.access_token}));
    await rpc('social_cron_save', {secret, patch: {token: long.access_token, threads_user_id: me.id, threads_username: me.username, last_error: null}});
    return back(request, 'connected');
  } catch (e) {
    return back(request, e.message);
  }
}
