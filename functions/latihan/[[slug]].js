// Cloudflare Pages Function: /latihan and /latihan/<topic>.
// The app is a single page, so link previews (Threads, WhatsApp) would all show the generic 10nis card.
// This serves the same index.html with the topic's title, description and picture in <title> and the OG tags.
// Unknown topics get the 404 page with a 404 status.

const SITE = 'https://10nis.win';

export async function onRequestGet({request, env, params}) {
  const url = new URL(request.url);
  const parts = params.slug || [];
  const [page, data] = await Promise.all([
    env.ASSETS.fetch(new URL('/', url)),
    env.ASSETS.fetch(new URL('/latihan.json', url)).then(r => r.json()).catch(() => null),
  ]);
  if (!data) return page;
  const t = parts.length === 1 ? data.topics.find(x => x.slug === parts[0]) : null;
  if (parts.length && !t) {
    const nf = await env.ASSETS.fetch(new URL('/404.html', url));
    return new Response(nf.body, {status: 404, headers: nf.headers});
  }
  const title = t ? `${t.title} · Latihan tenis · 10nis` : 'Latihan tenis · 10nis';
  const desc = t ? `${t.hook} ${t.steps.map(x => x.t).join(' · ')}` : 'Tips teknik tenis singkat: checkpoint dan 1 drill per topik. Split step, forehand, backhand, servis, volley, return dan lainnya.';
  const link = `${SITE}/latihan${t ? '/' + t.slug : ''}`;
  const img = t && t.img ? SITE + t.img : null;
  const set = v => ({element(e) { e.setAttribute('content', v); }});
  let rw = new HTMLRewriter()
    .on('html', {element(e) { e.setAttribute('lang', 'id'); }})
    .on('title', {element(e) { e.setInnerContent(title); }})
    .on('meta[name="description"]', set(desc))
    .on('meta[property="og:title"]', set(title))
    .on('meta[property="og:description"]', set(desc))
    .on('meta[property="og:url"]', set(link))
    .on('head', {element(e) { e.append(`<link rel="canonical" href="${link}">`, {html: true}); }});
  if (img) {
    // Portrait post pictures (720×900) instead of the wide default card.
    rw = rw.on('meta[property="og:image"]', set(img))
      .on('meta[property="og:image:width"]', set('720'))
      .on('meta[property="og:image:height"]', set('900'))
      .on('meta[name="twitter:card"]', set('summary_large_image'));
  }
  const res = rw.transform(page);
  const headers = new Headers(res.headers);
  headers.set('cache-control', 'no-cache');
  return new Response(res.body, {status: 200, headers});
}
