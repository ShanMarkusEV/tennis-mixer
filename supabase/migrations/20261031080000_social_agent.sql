-- Threads agent for the 10nis account. Every 15 minutes pg_cron calls https://10nis.win/api/social/run, which
-- publishes what the admin approved, and once a day finds matching Threads conversations and drafts replies
-- and a post with Claude. Drafts wait in social_queue until the admin approves them in /ad4min (replies to
-- comments on our own posts can go out automatically when auto_own_replies is on).
-- Access: the Cloudflare function proves itself with a shared cron secret (only its SHA-256 is stored here;
-- the secret itself lives in Supabase Vault for pg_cron and in Cloudflare); the admin console uses the admin
-- check (admins list + authenticator code). Nothing here is readable through the API otherwise; the Threads
-- token is never returned to any browser.

create extension if not exists pg_cron;
create extension if not exists pg_net;

create table public.social_config (
  id int primary key default 1 check (id = 1),
  queries text[] not null default array['cari partner tenis', 'main tenis', 'tenis jakarta', 'americano tenis', 'mabar tenis'],
  voice text not null default
    '10nis (10nis.win) is a free web app for social tennis groups in Indonesia: fair rotating doubles or singles rounds '
    '(Social = new partner every round, Competitive = matched by standings), scores and standings, a game PIN so players '
    'see their court live and get notified, levels 1-10, and importing players from Kuyy or Reclub links. '
    'Voice: friendly fellow tennis player, casual Indonesian (or English if the post is English), short, no hard sell, '
    'no hashtags, at most one emoji.' check (char_length(voice) <= 2000),
  auto_own_replies boolean not null default true,
  max_replies_day int not null default 8 check (max_replies_day between 0 and 30),
  max_posts_day int not null default 1 check (max_posts_day between 0 and 5),
  threads_user_id text,
  threads_username text,
  token text,
  token_refreshed_at timestamptz,
  last_discovery timestamptz,
  last_run timestamptz,
  last_error text,
  cron_secret_sha256 text
);
insert into public.social_config (id) values (1);
alter table public.social_config enable row level security;
revoke all on public.social_config from anon, authenticated;

create table public.social_queue (
  id bigserial primary key,
  kind text not null check (kind in ('post', 'reply', 'own_reply')),
  status text not null default 'draft' check (status in ('draft', 'approved', 'posted', 'skipped', 'failed')),
  text text not null check (char_length(text) between 1 and 500),
  target_id text,
  target_author text,
  target_text text,
  target_url text,
  query text,
  score numeric,
  reason text,
  creation_id text,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  posted_at timestamptz,
  posted_id text,
  posted_url text,
  error text
);
create index social_queue_status_idx on public.social_queue (status, created_at desc);
create unique index social_queue_target_idx on public.social_queue (target_id) where target_id is not null;
alter table public.social_queue enable row level security;
revoke all on public.social_queue from anon, authenticated;

create table public.social_seen (
  media_id text primary key,
  seen_at timestamptz not null default now()
);
alter table public.social_seen enable row level security;
revoke all on public.social_seen from anon, authenticated;

create function public.social_secret_ok(secret text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(char_length(secret), 0) >= 32 and exists (
    select 1 from public.social_config c where c.cron_secret_sha256 = encode(extensions.digest(secret, 'sha256'), 'hex'));
$$;
revoke execute on function public.social_secret_ok(text) from public, anon, authenticated;

create function public.social_require(secret text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.social_secret_ok(secret) then raise exception 'Not allowed' using errcode = '42501'; end if;
end;
$$;
revoke execute on function public.social_require(text) from public, anon, authenticated;

-- ---------- for the Cloudflare function ----------
-- Everything one run needs: settings and token, approved items, and today's counts (Jakarta days).
create function public.social_cron_state(secret text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
  cfg record;
begin
  perform public.social_require(secret);
  -- Housekeeping: forget seen posts after 30 days, and other people's post text after 30 days.
  delete from public.social_seen where seen_at < now() - interval '30 days';
  update public.social_queue set target_text = null, target_author = null
    where created_at < now() - interval '30 days' and (target_text is not null or target_author is not null);
  select * into cfg from public.social_config where id = 1;
  return jsonb_build_object(
    'queries', cfg.queries, 'voice', cfg.voice, 'auto_own_replies', cfg.auto_own_replies,
    'max_replies_day', cfg.max_replies_day, 'max_posts_day', cfg.max_posts_day,
    'threads_user_id', cfg.threads_user_id, 'threads_username', cfg.threads_username,
    'token', cfg.token, 'token_refreshed_at', cfg.token_refreshed_at, 'last_discovery', cfg.last_discovery,
    'approved', (select coalesce(jsonb_agg(to_jsonb(q) order by q.decided_at nulls first, q.id), '[]')
                 from public.social_queue q where q.status = 'approved'),
    'replies_today', (select count(*) from public.social_queue where kind <> 'post' and status = 'posted' and posted_at >= day_start),
    'posts_today', (select count(*) from public.social_queue where kind = 'post' and status = 'posted' and posted_at >= day_start),
    'drafted_post_today', exists (select 1 from public.social_queue where kind = 'post' and created_at >= day_start),
    'last_reply_at', (select max(posted_at) from public.social_queue where kind <> 'post' and status = 'posted'),
    'authors_today', (select coalesce(jsonb_agg(distinct target_author), '[]') from public.social_queue
                      where kind <> 'post' and status = 'posted' and posted_at >= day_start and target_author is not null),
    'recent_posts', (select coalesce(jsonb_agg(t.text), '[]') from (select text from public.social_queue
                      where kind = 'post' order by created_at desc limit 10) t));
end;
$$;

-- Which of these Threads posts haven't been looked at yet (and remember them all).
create function public.social_cron_seen(secret text, ids text[])
returns text[]
language plpgsql
security definer
set search_path = ''
as $$
declare fresh text[];
begin
  perform public.social_require(secret);
  select coalesce(array_agg(i), '{}') into fresh from unnest(ids) i
    where i is not null and not exists (select 1 from public.social_seen s where s.media_id = i);
  insert into public.social_seen (media_id) select unnest(fresh) on conflict do nothing;
  return fresh;
end;
$$;

-- Add drafts: [{kind, text, target_id, target_author, target_text, target_url, query, score, reason, status}].
create function public.social_cron_add(secret text, items jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare n int;
begin
  perform public.social_require(secret);
  insert into public.social_queue (kind, status, text, target_id, target_author, target_text, target_url, query, score, reason)
    select i ->> 'kind',
      case when i ->> 'status' = 'approved' and i ->> 'kind' = 'own_reply' then 'approved' else 'draft' end,
      left(i ->> 'text', 500), i ->> 'target_id', left(i ->> 'target_author', 100), left(i ->> 'target_text', 1000),
      left(i ->> 'target_url', 300), left(i ->> 'query', 100), (i ->> 'score')::numeric, left(i ->> 'reason', 300)
    from jsonb_array_elements(coalesce(items, '[]')) i
    where coalesce(i ->> 'text', '') <> '' and i ->> 'kind' in ('post', 'reply', 'own_reply')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

create function public.social_cron_mark(secret text, qid bigint, new_status text, pid text default null, purl text default null,
                                         err text default null, creation text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.social_require(secret);
  if new_status not in ('approved', 'posted', 'failed') then raise exception 'Bad status'; end if;
  update public.social_queue set status = new_status, posted_id = coalesce(pid, posted_id), posted_url = coalesce(purl, posted_url),
    error = left(err, 500), creation_id = coalesce(creation, creation_id),
    posted_at = case when new_status = 'posted' then now() else posted_at end
  where id = qid;
end;
$$;

-- Save run results: token after a refresh, account id, last run/discovery/error.
create function public.social_cron_save(secret text, patch jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.social_require(secret);
  update public.social_config set
    token = case when patch ? 'token' then patch ->> 'token' else token end,
    token_refreshed_at = case when patch ? 'token' then now() else token_refreshed_at end,
    threads_user_id = coalesce(patch ->> 'threads_user_id', threads_user_id),
    threads_username = coalesce(patch ->> 'threads_username', threads_username),
    last_discovery = case when patch ? 'last_discovery' then (patch ->> 'last_discovery')::timestamptz else last_discovery end,
    last_run = now(),
    last_error = case when patch ? 'last_error' then left(patch ->> 'last_error', 500) else last_error end
  where id = 1;
end;
$$;

revoke execute on function public.social_cron_state(text), public.social_cron_seen(text, text[]), public.social_cron_add(text, jsonb),
  public.social_cron_mark(text, bigint, text, text, text, text, text), public.social_cron_save(text, jsonb) from public;
grant execute on function public.social_cron_state(text), public.social_cron_seen(text, text[]), public.social_cron_add(text, jsonb),
  public.social_cron_mark(text, bigint, text, text, text, text, text), public.social_cron_save(text, jsonb) to anon, authenticated;

-- ---------- for the admin console ----------
create function public.admin_social_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare cfg record;
begin
  perform public.require_admin();
  select * into cfg from public.social_config where id = 1;
  return jsonb_build_object(
    'queries', cfg.queries, 'voice', cfg.voice, 'auto_own_replies', cfg.auto_own_replies,
    'max_replies_day', cfg.max_replies_day, 'max_posts_day', cfg.max_posts_day,
    'connected', cfg.token is not null, 'threads_username', cfg.threads_username,
    'token_age_days', case when cfg.token_refreshed_at is null then null else extract(day from now() - cfg.token_refreshed_at)::int end,
    'last_run', cfg.last_run, 'last_discovery', cfg.last_discovery, 'last_error', cfg.last_error,
    'cron_ready', cfg.cron_secret_sha256 is not null,
    'counts', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from public.social_queue group by 1) s));
end;
$$;

create function public.admin_social_list(st text, lim int default 50, off int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();
  return (select coalesce(jsonb_agg(to_jsonb(q) - 'creation_id' order by
      case when st in ('draft', 'approved') then q.created_at end desc, coalesce(q.posted_at, q.decided_at, q.created_at) desc), '[]')
    from (select * from public.social_queue
          where status = any(case when st = 'history' then array['posted', 'skipped', 'failed'] else array[st] end)
          order by created_at desc limit greatest(1, least(coalesce(lim, 50), 200)) offset greatest(0, coalesce(off, 0))) q);
end;
$$;

-- Approve (optionally with edited text) or skip a draft; a failed item can be approved again.
create function public.admin_social_decide(qid bigint, new_text text, approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare t text := trim(coalesce(new_text, ''));
begin
  perform public.require_admin();
  if approve and char_length(t) not between 1 and 500 then raise exception 'Text must be 1 to 500 characters'; end if;
  update public.social_queue set
    text = case when approve then t else text end,
    status = case when approve then 'approved' else 'skipped' end,
    decided_at = now(), error = null
  where id = qid and status in ('draft', 'failed', 'approved');
  if not found then raise exception 'That item was already handled'; end if;
  perform public.admin_note(case when approve then 'approve threads item' else 'skip threads item' end, qid::text);
end;
$$;

-- Settings: queries, voice, toggles, caps, and the Threads token (write-only).
create function public.admin_social_config(patch jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare q text[];
begin
  perform public.require_admin();
  if patch ? 'queries' then
    select coalesce(array_agg(left(trim(x), 60)), '{}') into q from jsonb_array_elements_text(patch -> 'queries') x where trim(x) <> '';
    if cardinality(q) > 10 then raise exception 'Use at most 10 search queries'; end if;
  end if;
  update public.social_config set
    queries = coalesce(q, queries),
    voice = case when patch ? 'voice' then left(coalesce(patch ->> 'voice', ''), 2000) else voice end,
    auto_own_replies = coalesce((patch ->> 'auto_own_replies')::boolean, auto_own_replies),
    max_replies_day = coalesce((patch ->> 'max_replies_day')::int, max_replies_day),
    max_posts_day = coalesce((patch ->> 'max_posts_day')::int, max_posts_day),
    token = case when patch ? 'clear_token' then null when nullif(trim(patch ->> 'token'), '') is not null then trim(patch ->> 'token') else token end,
    token_refreshed_at = case when patch ? 'clear_token' then null when nullif(trim(patch ->> 'token'), '') is not null then now() else token_refreshed_at end,
    threads_user_id = case when patch ? 'token' or patch ? 'clear_token' then null else threads_user_id end,
    threads_username = case when patch ? 'token' or patch ? 'clear_token' then null else threads_username end,
    last_error = case when patch ? 'token' then null else last_error end
  where id = 1;
  perform public.admin_note('threads settings', null, patch - 'token');
end;
$$;

revoke execute on function public.admin_social_state(), public.admin_social_list(text, int, int),
  public.admin_social_decide(bigint, text, boolean), public.admin_social_config(jsonb) from public, anon;
grant execute on function public.admin_social_state(), public.admin_social_list(text, int, int),
  public.admin_social_decide(bigint, text, boolean), public.admin_social_config(jsonb) to authenticated;

-- ---------- schedule ----------
-- The secret is read from Vault at run time (set up outside this file); without it the function refuses.
select cron.schedule('social-run', '*/15 * * * *', $cron$
  select net.http_post(
    url := 'https://10nis.win/api/social/run',
    headers := jsonb_build_object('content-type', 'application/json',
      'x-cron-secret', coalesce((select decrypted_secret from vault.decrypted_secrets where name = 'social_cron_secret'), '')),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000);
$cron$);
