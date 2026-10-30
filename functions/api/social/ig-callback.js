// Cloudflare Pages Function: GET /api/social/ig-callback — Instagram sends the admin back here after approving.
// Checks the one-time state, swaps the code for a 1-hour token and that for a 60-day token (with the App Secret,
// which never leaves Cloudflare), stores it, and returns to /ad4min.
// Needs INSTAGRAM_APP_ID, INSTAGRAM_APP_SECRET and SOCIAL_CRON_SECRET.
import {rpc} from './_lib.js';

const back = (request, result) => Response.redirect(new URL(`/ad4min?instagram=${encodeURIComponent(result)}`, request.url).toString(), 302);

export async function onRequestGet({request, env}) {
  const p = new URL(request.url).searchParams;
  if (p.get('error')) return back(request, p.get('error_description') || p.get('error'));
  if (!env.INSTAGRAM_APP_ID || !env.INSTAGRAM_APP_SECRET || !env.SOCIAL_CRON_SECRET) return back(request, 'Instagram app secrets are not set in Cloudflare');
  const secret = env.SOCIAL_CRON_SECRET;
  try {
    if (!(await rpc('social_cron_oauth_take', {secret, st: p.get('state') || ''}))) return back(request, 'This sign-in link expired. Try Connect Instagram again');
    const call = async (url, init) => {
      const r = await fetch(url, init);
      const d = await r.json().catch(() => ({}));
      if (!r.ok || d.error || d.error_message) throw new Error((d.error && (d.error.message || d.error)) || d.error_message || `Instagram returned ${r.status}`);
      return d;
    };
    const api = env.INSTAGRAM_OAUTH_BASE || 'https://api.instagram.com', graph = env.INSTAGRAM_GRAPH || 'https://graph.instagram.com';
    const code = (p.get('code') || '').replace(/#_$/, '');
    let short = await call(api + '/oauth/access_token', {method: 'POST', body: new URLSearchParams({client_id: env.INSTAGRAM_APP_ID,
      client_secret: env.INSTAGRAM_APP_SECRET, grant_type: 'authorization_code', code,
      redirect_uri: new URL('/api/social/ig-callback', request.url).toString()})});
    if (Array.isArray(short.data)) short = short.data[0] || {};
    const long = await call(graph + '/access_token?' + new URLSearchParams({grant_type: 'ig_exchange_token',
      client_secret: env.INSTAGRAM_APP_SECRET, access_token: short.access_token}));
    const me = await call(graph + '/v26.0/me?' + new URLSearchParams({fields: 'user_id,username', access_token: long.access_token}));
    await rpc('social_cron_save', {secret, patch: {ig_token: long.access_token, ig_user_id: String(me.user_id || me.id), ig_username: me.username}});
    return back(request, 'connected');
  } catch (e) {
    return back(request, e.message);
  }
}
