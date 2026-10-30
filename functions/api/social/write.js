// Cloudflare Pages Function: POST /api/social/write — Claude writes a promo post for the Compose screen in /ad4min.
// Body {idea?, image?}; returns {text}. Only for a signed-in admin; nothing is posted or saved here.
import {json} from '../_shared.js';
import {rpc, isAdmin, draft, TOPICS} from './_lib.js';

const SHOT_TOPIC = Object.fromEntries(TOPICS.map(([topic, shot]) => [shot, topic]));

export async function onRequestPost({request, env}) {
  if (!env.SOCIAL_CRON_SECRET) return json({error: 'The social agent is not set up yet (SOCIAL_CRON_SECRET)'}, 503);
  if (!(await isAdmin(request))) return json({error: 'Not allowed'}, 403);
  const body = await request.json().catch(() => ({}));
  const idea = String(body.idea || '').slice(0, 500).trim();
  const shot = (String(body.image || '').match(/^promo\/([a-z0-9-]+)\.jpg$/) || [])[1];
  try {
    const S = await rpc('social_cron_state', {secret: env.SOCIAL_CRON_SECRET});
    const out = await draft(env, {voice: S.voice, items: [], wantPost: true, recentPosts: S.recent_posts, idea,
      topic: SHOT_TOPIC[shot] || TOPICS[Math.floor(Math.random() * TOPICS.length)][0]});
    return json({text: String(out.post || '').trim().slice(0, 500)});
  } catch (e) {
    return json({error: e.message}, 502);
  }
}
