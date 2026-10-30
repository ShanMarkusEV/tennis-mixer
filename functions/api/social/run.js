// Cloudflare Pages Function: POST /api/social/run — one run of the 10nis Threads agent.
// Called every 15 minutes by Supabase pg_cron (header x-cron-secret), or by the admin console's "Run now"
// (an admin login that passed the authenticator code). ?dry=1 drafts without publishing; ?discover=1 forces
// today's discovery to run again.
//   1. Publish at most one approved item per run, within the daily caps, 10+ minutes between replies, and at
//      most one reply per person per day.
//   2. Once a day (from 08:00 Jakarta time): find new matching posts, comments on our posts and mentions,
//      and draft replies plus one original post with Claude. Drafts wait for approval in /ad4min, except replies
//      to comments on our own posts when auto-reply is on.
// Needs Cloudflare secrets SOCIAL_CRON_SECRET and ANTHROPIC_API_KEY; the Threads token is set in /ad4min.
import {json} from '../_shared.js';
import {rpc, threads, draft, TOPICS} from './_lib.js';

const MIN_REPLY_GAP_MS = 10 * 60e3;
const jakarta = d => new Date(new Date(d).getTime() + 7 * 3600e3);   // UTC+7, no DST

async function sameSecret(a, b) {
  const enc = s => crypto.subtle.digest('SHA-256', new TextEncoder().encode(String(s || '')));
  const [x, y] = await Promise.all([enc(a), enc(b)]);
  return crypto.subtle.timingSafeEqual(x, y) && !!a;
}

export async function onRequestPost({request, env}) {
  const secret = env.SOCIAL_CRON_SECRET;
  if (!secret) return json({error: 'The Threads agent is not set up yet (SOCIAL_CRON_SECRET)'}, 503);
  const url = new URL(request.url), dry = url.searchParams.get('dry') === '1';
  let force = url.searchParams.get('discover') === '1';
  if (!(await sameSecret(request.headers.get('x-cron-secret'), secret))) {
    const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    const chk = token ? await rpc('admin_check', {}, token).catch(() => null) : null;
    if (!chk || !chk.listed || chk.aal !== 'aal2') return json({error: 'Not allowed'}, 403);
  }

  const S = await rpc('social_cron_state', {secret});
  const save = {}, log = [];
  try {
    if (!S.token) throw new Error('No Threads token yet: paste one in /ad4min → Threads');
    const T = threads(S.token, env.THREADS_API_BASE);
    if (!S.threads_user_id) {
      const me = await T.get('/me', {fields: 'id,username'});
      S.threads_user_id = save.threads_user_id = me.id; S.threads_username = save.threads_username = me.username;
      force = true;   // first run with a new token: draft straight away
    }
    if (!S.token_refreshed_at || Date.now() - new Date(S.token_refreshed_at) > 30 * 864e5) {
      const r = await T.refresh();
      if (r.access_token) { save.token = r.access_token; log.push('token refreshed'); }
    }
    if (!dry) log.push(await publishOne(T, S));
    const now = jakarta(Date.now()), last = S.last_discovery && jakarta(S.last_discovery);
    const due = !last || (last.toISOString().slice(0, 10) < now.toISOString().slice(0, 10) && now.getUTCHours() >= 8);
    if (due || force) { log.push(await discover(T, S, env)); save.last_discovery = new Date().toISOString(); }
    save.last_error = null;
  } catch (e) {
    save.last_error = e.message;
    log.push('error: ' + e.message);
  }
  await rpc('social_cron_save', {secret, patch: save});
  return json({ok: !save.last_error, dry, log: log.filter(Boolean)});

  // ---------- 1. publish ----------
  async function publishOne(T, S) {
    const lastReply = S.last_reply_at ? new Date(S.last_reply_at).getTime() : 0;
    const item = S.approved.find(q => q.kind === 'post'
      ? S.posts_today < S.max_posts_day
      : S.replies_today < S.max_replies_day && Date.now() - lastReply >= MIN_REPLY_GAP_MS
        && !(q.target_author && S.authors_today.includes(q.target_author)));
    if (!item) return S.approved.length ? `${S.approved.length} approved, waiting for daily limits or spacing` : null;
    const mark = (status, extra = {}) => rpc('social_cron_mark', {secret, qid: item.id, new_status: status, ...extra});
    let creation = item.creation_id;
    try {
      if (!creation) {
        const c = await T.post(`/${S.threads_user_id}/threads`, {media_type: 'TEXT', text: item.text,
          ...(item.kind !== 'post' && item.target_id ? {reply_to_id: item.target_id} : {})});
        creation = c.id;
      }
      const p = await T.post(`/${S.threads_user_id}/threads_publish`, {creation_id: creation});
      const m = await T.get(`/${p.id}`, {fields: 'permalink'}).catch(() => ({}));
      await mark('posted', {pid: p.id, purl: m.permalink || null});
      return `posted ${item.kind} #${item.id}`;
    } catch (e) {
      // Meta asks to give a new post a moment before publishing: a first failure keeps the post for the next run.
      if (creation && !item.creation_id) { await mark('approved', {creation, err: e.message}); return `#${item.id} will publish next run`; }
      await mark('failed', {err: e.message});
      return `#${item.id} failed: ${e.message}`;
    }
  }

  // ---------- 2. discover and draft ----------
  async function discover(T, S, env) {
    const me = S.threads_username, since = Math.floor(Date.now() / 1000) - 48 * 3600;
    const fields = 'id,text,username,permalink,timestamp';
    const found = [];
    // Comments on our recent posts, and mentions of us.
    const mine = await T.get(`/${S.threads_user_id}/threads`, {fields: 'id,timestamp', limit: 5}).catch(() => ({data: []}));
    for (const post of (mine.data || []).filter(p => Date.now() - new Date(p.timestamp) < 7 * 864e5)) {
      const r = await T.get(`/${post.id}/replies`, {fields}).catch(() => ({data: []}));
      (r.data || []).forEach(x => found.push({...x, kind: 'own_reply'}));
    }
    const ment = await T.get(`/${S.threads_user_id}/mentions`, {fields, limit: 10}).catch(() => ({data: []}));
    (ment.data || []).forEach(x => found.push({...x, kind: 'own_reply'}));
    // Conversations matching the saved queries.
    for (const q of S.queries) {
      const r = await T.get('/keyword_search', {q, search_type: 'RECENT', fields, since, limit: 25}).catch(() => ({data: []}));
      (r.data || []).forEach(x => found.push({...x, kind: 'reply', query: q}));
    }
    const usable = found.filter(x => x.id && x.text && x.username && x.username !== me);
    const unique = [...new Map(usable.map(x => [x.id, x])).values()];
    const fresh = new Set(unique.length ? await rpc('social_cron_seen', {secret, ids: unique.map(x => x.id)}) : []);
    const items = unique.filter(x => fresh.has(x.id))
      .sort((a, b) => (a.kind === 'own_reply' ? 0 : 1) - (b.kind === 'own_reply' ? 0 : 1)).slice(0, 20);
    const wantPost = !S.drafted_post_today && S.max_posts_day > 0;
    if (!items.length && !wantPost) return `nothing new (${found.length} found)`;

    const out = await draft(env, {voice: S.voice, wantPost, recentPosts: S.recent_posts,
      topic: TOPICS[Math.floor(Date.now() / 864e5) % TOPICS.length],
      items: items.map((x, i) => ({i, kind: x.kind, author: x.username, text: x.text.slice(0, 600), query: x.query || null}))});
    const drafts = (out.replies || []).map(d => {
      const x = items[d.i];
      if (!x || !d.reply || d.relevant < (x.kind === 'own_reply' ? 0.3 : 0.6)) return null;
      return {kind: x.kind, text: d.reply.slice(0, 500), target_id: x.id, target_author: x.username, target_text: x.text,
        target_url: x.permalink, query: x.query || null, score: d.relevant, reason: d.reason,
        status: x.kind === 'own_reply' && S.auto_own_replies ? 'approved' : 'draft'};
    }).filter(Boolean);
    if (wantPost && out.post && out.post.trim()) drafts.push({kind: 'post', text: out.post.trim().slice(0, 500)});
    const added = drafts.length ? await rpc('social_cron_add', {secret, items: drafts}) : 0;
    return `${found.length} found, ${items.length} new, ${added} drafted`;
  }
}
