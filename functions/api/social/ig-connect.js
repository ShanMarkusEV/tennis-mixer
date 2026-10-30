// Cloudflare Pages Function: GET /api/social/ig-connect?state=… — sends the admin to Instagram to approve the app
// (Instagram API with Instagram Login; the account must be a professional one). /api/social/ig-callback checks the state.
// Needs INSTAGRAM_APP_ID (App Dashboard > Instagram > API setup with Instagram login > Instagram app ID).
import {json} from '../_shared.js';

export const IG_SCOPES = 'instagram_business_basic,instagram_business_content_publish';

export async function onRequestGet({request, env}) {
  const state = new URL(request.url).searchParams.get('state') || '';
  if (!env.INSTAGRAM_APP_ID) return json({error: 'INSTAGRAM_APP_ID is not set in Cloudflare'}, 503);
  if (!/^[0-9a-f]{64}$/.test(state)) return json({error: 'Start from /ad4min → Social agent → Accounts → Connect Instagram'}, 400);
  const u = new URL(env.INSTAGRAM_AUTH_URL || 'https://www.instagram.com/oauth/authorize');
  u.search = new URLSearchParams({client_id: env.INSTAGRAM_APP_ID, redirect_uri: new URL('/api/social/ig-callback', request.url).toString(),
    scope: IG_SCOPES, response_type: 'code', state}).toString();
  return Response.redirect(u.toString(), 302);
}
