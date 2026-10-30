-- Threads agent: the daily post goes out on its own (auto_post) under a chosen topic tag, Threads' "channel"
-- for a post (post_topic, e.g. Tennis). The database decides which drafts may arrive already approved, from
-- the settings, instead of trusting the caller.

alter table public.social_config
  add column post_topic text default 'Tennis' check (post_topic is null or (char_length(post_topic) <= 50 and post_topic !~ '[.&]')),
  add column auto_post boolean not null default true;
alter table public.social_queue add column topic text check (topic is null or (char_length(topic) <= 50 and topic !~ '[.&]'));

create or replace function public.social_cron_add(secret text, items jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
  cfg record;
begin
  perform public.social_require(secret);
  select * into cfg from public.social_config where id = 1;
  insert into public.social_queue (kind, status, text, target_id, target_author, target_text, target_url, query, score, reason, topic)
    select i ->> 'kind',
      case when (i ->> 'kind' = 'own_reply' and cfg.auto_own_replies) or (i ->> 'kind' = 'post' and cfg.auto_post)
           then 'approved' else 'draft' end,
      left(i ->> 'text', 500), i ->> 'target_id', left(i ->> 'target_author', 100), left(i ->> 'target_text', 1000),
      left(i ->> 'target_url', 300), left(i ->> 'query', 100), (i ->> 'score')::numeric, left(i ->> 'reason', 300),
      case when i ->> 'kind' = 'post' then cfg.post_topic end
    from jsonb_array_elements(coalesce(items, '[]')) i
    where coalesce(i ->> 'text', '') <> '' and i ->> 'kind' in ('post', 'reply', 'own_reply')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.social_cron_state(secret text)
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
  delete from public.social_seen where seen_at < now() - interval '30 days';
  update public.social_queue set target_text = null, target_author = null
    where created_at < now() - interval '30 days' and (target_text is not null or target_author is not null);
  select * into cfg from public.social_config where id = 1;
  return jsonb_build_object(
    'queries', cfg.queries, 'voice', cfg.voice, 'auto_own_replies', cfg.auto_own_replies, 'auto_post', cfg.auto_post,
    'post_topic', cfg.post_topic, 'max_replies_day', cfg.max_replies_day, 'max_posts_day', cfg.max_posts_day,
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

create or replace function public.admin_social_state()
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
    'queries', cfg.queries, 'voice', cfg.voice, 'auto_own_replies', cfg.auto_own_replies, 'auto_post', cfg.auto_post,
    'post_topic', cfg.post_topic, 'max_replies_day', cfg.max_replies_day, 'max_posts_day', cfg.max_posts_day,
    'connected', cfg.token is not null, 'threads_username', cfg.threads_username,
    'token_age_days', case when cfg.token_refreshed_at is null then null else extract(day from now() - cfg.token_refreshed_at)::int end,
    'last_run', cfg.last_run, 'last_discovery', cfg.last_discovery, 'last_error', cfg.last_error,
    'cron_ready', cfg.cron_secret_sha256 is not null,
    'counts', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from public.social_queue group by 1) s));
end;
$$;

create or replace function public.admin_social_config(patch jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  q text[];
  topic text := nullif(trim(coalesce(patch ->> 'post_topic', '')), '');
begin
  perform public.require_admin();
  if patch ? 'queries' then
    select coalesce(array_agg(left(trim(x), 60)), '{}') into q from jsonb_array_elements_text(patch -> 'queries') x where trim(x) <> '';
    if cardinality(q) > 10 then raise exception 'Use at most 10 search queries'; end if;
  end if;
  if topic ~ '[.&]' then raise exception 'Topics can''t contain . or &'; end if;
  if trim(coalesce(patch ->> 'token', '')) ~ '^[0-9a-fA-F]{32}$' then
    raise exception 'That looks like the App Secret. Paste the user access token instead (it usually starts with TH)';
  end if;
  update public.social_config set
    queries = coalesce(q, queries),
    voice = case when patch ? 'voice' then left(coalesce(patch ->> 'voice', ''), 2000) else voice end,
    auto_own_replies = coalesce((patch ->> 'auto_own_replies')::boolean, auto_own_replies),
    auto_post = coalesce((patch ->> 'auto_post')::boolean, auto_post),
    post_topic = case when patch ? 'post_topic' then left(topic, 50) else post_topic end,
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
