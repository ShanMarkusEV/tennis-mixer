// Cloudflare Pages Function: GET /api/social/connect?state=… — sends the admin to Threads to approve the app.
// The state comes from admin_social_oauth_start() in /ad4min; /api/social/callback checks it.
// Needs THREADS_APP_ID (App Dashboard > App settings > Basic > Threads App ID).
import {json} from '../_shared.js';

export const SCOPES = 'threads_basic,threads_content_publish,threads_manage_replies,threads_read_replies,threads_manage_mentions,threads_keyword_search';

export async function onRequestGet({request, env}) {
  const state = new URL(request.url).searchParams.get('state') || '';
  if (!env.THREADS_APP_ID) return json({error: 'THREADS_APP_ID is not set in Cloudflare'}, 503);
  if (!/^[0-9a-f]{64}$/.test(state)) return json({error: 'Start from /ad4min → Threads → Connect Threads'}, 400);
  const u = new URL(env.THREADS_AUTH_URL || 'https://threads.com/oauth/authorize');
  u.search = new URLSearchParams({client_id: env.THREADS_APP_ID, redirect_uri: new URL('/api/social/callback', request.url).toString(),
    scope: SCOPES, response_type: 'code', state}).toString();
  return Response.redirect(u.toString(), 302);
}
