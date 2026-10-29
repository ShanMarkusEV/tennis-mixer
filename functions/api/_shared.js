// Helpers shared by the Kuyy/Reclub functions. Not a route: it exports no request handler.

export const UA = 'Mozilla/5.0 (compatible; TennisMixer/1.0; +https://10nis.win)';
export const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'}
});
export const isHost = (host, domain) => host === domain || host.endsWith('.' + domain);

// ---------- levels (app scale 1–10) ----------
// Kuyy activities only say the level in the title, in English or Indonesian, often abbreviated
// ("UPPER BEG - LOWER INTER"). Most specific patterns first; each match is blanked so "upper beginner"
// is not also counted as "beginner".
const TITLE_LEVELS = [
  [/\bupper\s*beg(inner)?s?\b/g, 4, 5.5],
  [/\b(low|lower)\s*inter(mediate)?s?\b/g, 5, 6.5],
  [/\bupper\s*inter(mediate)?s?\b/g, 7, 8.5],
  [/\binter(mediate)?s?\b|\bmenengah\b/g, 6, 8],
  [/\bnewbies?\b|\bpemula banget\b/g, 1, 2],
  [/\bbeg(inner)?s?\b|\bpemula\b/g, 2, 4],
  [/\badv(anced?)?\b|\bmahir\b|\blanjutan\b/g, 8, 10],
  [/\bpro\b/g, 9, 10],
];
export function levelFromTitle(title) {
  let t = String(title || '').toLowerCase();
  const up = /(&|\band\b|\+)\s*up\b|\bke atas\b/.test(t);
  let lo = Infinity, hi = -Infinity;
  for (const [re, a, b] of TITLE_LEVELS) {
    if (!re.test(t)) { re.lastIndex = 0; continue; }
    re.lastIndex = 0;
    t = t.replace(re, ' ');
    lo = Math.min(lo, a); hi = Math.max(hi, b);
  }
  if (lo === Infinity) return null;
  return {min: lo, max: up ? 10 : hi};
}
// Reclub levels run 1 (Newbie) to 5 (Advanced).
export const reclubLevel = v => v == null ? null : Math.max(1, Math.min(10, 1 + 2.25 * (Number(v) - 1)));

// ---------- activity dedupe key ----------
// The same session is often listed on both Kuyy and Reclub. date|hour (WIB) plus the first two
// meaningful words of the venue is enough to match them without fuzzy logic.
const VENUE_STOP = new Set(['court', 'courts', 'tennis', 'indoor', 'outdoor', 'lapangan', 'lap', 'the', 'club',
  'arena', 'sport', 'sports', 'center', 'centre', 'private', 'hall', 'stadium', 'stadion', 'gor']);
export function activityKey(startMs, venue) {
  if (!startMs || isNaN(startMs)) return null;
  const wib = new Date(startMs + 7 * 3600e3).toISOString(); // Asia/Jakarta is UTC+7, no DST
  const token = String(venue || '').toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/)
    .filter(w => w && !VENUE_STOP.has(w)).slice(0, 2).join('-') || 'unknown';
  return `${wib.slice(0, 10)}|${wib.slice(11, 13)}|${token}`;
}
export const wibDate = startMs => startMs && !isNaN(startMs) ? new Date(startMs + 7 * 3600e3).toISOString().slice(0, 10) : null;
