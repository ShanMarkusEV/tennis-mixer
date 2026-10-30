// Cloudflare Pages Function: POST /api/social/run — one run of the 10nis social agent (Threads and Instagram).
// Called every 15 minutes by Supabase pg_cron (header x-cron-secret), or by the admin console's "Run now"
// (an admin login that passed the authenticator code). ?dry=1 drafts without publishing; ?discover=1 forces
// today's discovery to run again.
//   1. Publish at most one due approved item per platform per run: the agent's posts and replies within the daily
//      caps (10+ minutes between replies, one reply per person a day); posts the admin wrote, at their set time.
//   With ?news=1 (a morning cron job, or "Generate news now"): draft tennis news posts for the open time slots.
//   2. Once a day (from 08:00 Jakarta time): find new matching posts, comments on our posts and mentions,
//      and draft replies plus one original post with Gemini (under its topic tag, with an app screenshot from
//      /promo). Every draft waits for approval in /ad4min; nothing is published without it.
// Needs Cloudflare secrets SOCIAL_CRON_SECRET and GEMINI_API_KEY; the Threads and Instagram tokens come from
// connecting the accounts in /ad4min.
import {json} from '../_shared.js';
import {rpc, isAdmin, threads, instagram, draft, newsDraft, TOPICS} from './_lib.js';

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
  const viaCron = await sameSecret(request.headers.get('x-cron-secret'), secret);
  if (!viaCron && !(await isAdmin(request))) return json({error: 'Not allowed'}, 403);
  if (url.searchParams.get('news') === '1') return json(await makeNews());

  const S = await rpc('social_cron_state', {secret});
  const save = {}, log = [];
  try {
    if (!S.token && !S.ig_token) throw new Error('Nothing connected yet: connect Threads or Instagram in /ad4min');
    const T = S.token && threads(S.token, env.THREADS_API_BASE);
    const I = S.ig_token && instagram(S.ig_token, env.INSTAGRAM_API_BASE);
    if (T && !S.threads_user_id) {
      const me = await T.get('/me', {fields: 'id,username'});
      S.threads_user_id = save.threads_user_id = me.id; S.threads_username = save.threads_username = me.username;
      force = true;   // first run with a new token: draft straight away
    }
    const old = d => !d || Date.now() - new Date(d) > 30 * 864e5;
    if (T && old(S.token_refreshed_at)) {
      const r = await T.refresh();
      if (r.access_token) { save.token = r.access_token; log.push('Threads token refreshed'); }
    }
    if (I && old(S.ig_token_refreshed_at)) {
      const r = await I.refresh().catch(e => ({error: e.message}));
      if (r.access_token) { save.ig_token = r.access_token; log.push('Instagram token refreshed'); }
    }
    if (!dry) {
      if (T) log.push(await publishOne('threads', T, S));
      if (I) log.push(await publishOne('instagram', I, S));
    }
    const now = jakarta(Date.now()), last = S.last_discovery && jakarta(S.last_discovery);
    const due = !last || (last.toISOString().slice(0, 10) < now.toISOString().slice(0, 10) && now.getUTCHours() >= 8);
    if (T && (due || force)) { log.push(await discover(T, S, env)); save.last_discovery = new Date().toISOString(); }
    save.last_error = null;
  } catch (e) {
    save.last_error = e.message;
    log.push('error: ' + e.message);
  }
  await rpc('social_cron_save', {secret, patch: save});
  return json({ok: !save.last_error, dry, log: log.filter(Boolean)});

  // ---------- 1. publish: at most one due item per platform per run ----------
  async function publishOne(platform, api, S) {
    const lastReply = S.last_reply_at ? new Date(S.last_reply_at).getTime() : 0;
    const mine = S.approved.filter(q => q.platform === platform);
    const item = mine.find(q => q.kind === 'news' ? true : q.kind === 'post'
      ? q.manual || S.posts_today[platform] < S.max_posts_day
      : S.replies_today < S.max_replies_day && Date.now() - lastReply >= MIN_REPLY_GAP_MS
        && !(q.target_author && S.authors_today.includes(q.target_author)));
    if (!item) return mine.length ? `${platform}: ${mine.length} approved, waiting for daily limits or spacing` : null;
    const mark = (status, extra = {}) => rpc('social_cron_mark', {secret, qid: item.id, new_status: status, ...extra});
    const image = item.image ? new URL('/' + item.image, request.url).href : null;
    let creation = item.creation_id;
    try {
      let link;
      if (platform === 'instagram') {
        if (!creation) creation = (await api.post(`/${S.ig_user_id}/media`, {image_url: image, caption: item.text})).id;
        const p = await api.post(`/${S.ig_user_id}/media_publish`, {creation_id: creation});
        link = (await api.get(`/${p.id}`, {fields: 'permalink'}).catch(() => ({}))).permalink;
        await mark('posted', {pid: p.id, purl: link || null});
      } else {
        if (!creation) {
          const c = await api.post(`/${S.threads_user_id}/threads`, {media_type: 'TEXT', text: item.text,
            ...(image ? {media_type: 'IMAGE', image_url: image} : {}),
            ...((item.kind === 'reply' || item.kind === 'own_reply') && item.target_id ? {reply_to_id: item.target_id} : {}),
            ...((item.kind === 'post' || item.kind === 'news') && item.topic ? {topic_tag: item.topic} : {})});
          creation = c.id;
        }
        const p = await api.post(`/${S.threads_user_id}/threads_publish`, {creation_id: creation});
        link = (await api.get(`/${p.id}`, {fields: 'permalink'}).catch(() => ({}))).permalink;
        await mark('posted', {pid: p.id, purl: link || null});
      }
      return `${platform}: posted ${item.kind} #${item.id}`;
    } catch (e) {
      // Meta asks to give a new post a moment before publishing: a first failure keeps the post for the next run.
      if (creation && !item.creation_id) { await mark('approved', {creation, err: e.message}); return `${platform}: #${item.id} will publish next run`; }
      await mark('failed', {err: e.message});
      return `${platform}: #${item.id} failed: ${e.message}`;
    }
  }

  // ---------- tennis news: one draft per open time slot, from what's on the web now ----------
  async function makeNews() {
    const N = await rpc('social_cron_news_state', {secret});
    if (viaCron && !N.enabled) return {ok: true, log: ['tennis news is off']};
    if (!N.connected) return {ok: false, error: 'Connect Threads first'};
    if (!N.open_slots.length) return {ok: true, log: ['every news slot already has a post']};
    try {
      const posts = await newsDraft(env, {voice: N.voice, count: N.open_slots.length, recent: N.recent});
      const items = posts.slice(0, N.open_slots.length).map((x, i) => ({...x, at: N.open_slots[i]}));
      const added = items.length ? await rpc('social_cron_add_news', {secret, items}) : 0;
      return {ok: true, log: [`${added} tennis news ${added === 1 ? 'post' : 'posts'} drafted for review`]};
    } catch (e) {
      await rpc('social_cron_save', {secret, patch: {last_error: 'Tennis news: ' + e.message}});
      return {ok: false, error: 'Tennis news: ' + e.message};
    }
  }

  // ---------- 2. discover and draft ----------
  async function discover(T, S, env) {
    const me = S.threads_username, since = Math.floor(Date.now() / 1000) - 48 * 3600;
    const fields = 'id,text,username,permalink,timestamp';
    const found = [], problems = new Set();
    // A failed call doesn't stop the rest, but the reason is reported (often a permission Meta hasn't granted yet).
    const none = what => e => { problems.add(`${what}: ${e.message.replace(/^Threads [^:]*: /, '')}`); return {data: []}; };
    // Comments on our recent posts, and mentions of us.
    const mine = await T.get(`/${S.threads_user_id}/threads`, {fields: 'id,timestamp', limit: 5}).catch(none('our posts'));
    for (const post of (mine.data || []).filter(p => Date.now() - new Date(p.timestamp) < 7 * 864e5)) {
      const r = await T.get(`/${post.id}/replies`, {fields}).catch(none('comments'));
      (r.data || []).forEach(x => found.push({...x, kind: 'own_reply'}));
    }
    const ment = await T.get(`/${S.threads_user_id}/mentions`, {fields, limit: 10}).catch(none('mentions'));
    (ment.data || []).forEach(x => found.push({...x, kind: 'own_reply'}));
    // Conversations matching the saved queries.
    for (const q of S.queries) {
      const r = await T.get('/keyword_search', {q, search_type: 'RECENT', fields, since, limit: 25}).catch(none('search'));
      (r.data || []).forEach(x => found.push({...x, kind: 'reply', query: q}));
    }
    const usable = found.filter(x => x.id && x.text && x.username && x.username !== me);
    const unique = [...new Map(usable.map(x => [x.id, x])).values()];
    const fresh = new Set(unique.length ? await rpc('social_cron_seen', {secret, ids: unique.map(x => x.id)}) : []);
    const items = unique.filter(x => fresh.has(x.id))
      .sort((a, b) => (a.kind === 'own_reply' ? 0 : 1) - (b.kind === 'own_reply' ? 0 : 1)).slice(0, 20);
    const wantPost = !S.drafted_post_today && S.max_posts_day > 0;
    const why = problems.size ? ` (couldn't read ${[...problems].join('; ')})` : '';
    if (!items.length && !wantPost) return `nothing new (${found.length} found)${why}`;

    const [topic, shot] = TOPICS[Math.floor(Date.now() / 864e5) % TOPICS.length];
    const out = await draft(env, {voice: S.voice, wantPost, recentPosts: S.recent_posts, topic,
      items: items.map((x, i) => ({i, kind: x.kind, author: x.username, text: x.text.slice(0, 600), query: x.query || null}))});
    const drafts = (out.replies || []).map(d => {
      const x = items[d.i];
      if (!x || !d.reply || d.relevant < (x.kind === 'own_reply' ? 0.3 : 0.6)) return null;
      return {kind: x.kind, text: d.reply.slice(0, 500), target_id: x.id, target_author: x.username, target_text: x.text,
        target_url: x.permalink, query: x.query || null, score: d.relevant, reason: d.reason};
    }).filter(Boolean);
    if (wantPost && out.post && out.post.trim()) drafts.push({kind: 'post', text: out.post.trim().slice(0, 500), image: `promo/${shot}.jpg`});
    const added = drafts.length ? await rpc('social_cron_add', {secret, items: drafts}) : 0;
    return `${found.length} found, ${items.length} new, ${added} drafted${why}`;
  }
}
