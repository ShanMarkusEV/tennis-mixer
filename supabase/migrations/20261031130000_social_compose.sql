-- Social agent: posts can go to Threads or Instagram, the admin can write (and schedule) posts in /ad4min, and the
-- daily drafted post can go to either or both. Instagram uses "Instagram API with Instagram Login" (a professional
-- account); its token is stored like the Threads one: write-only, never returned to a browser.

alter table public.social_config
  add column ig_token text,
  add column ig_token_refreshed_at timestamptz,
  add column ig_user_id text,
  add column ig_username text,
  add column daily_platforms text[] not null default array['threads']
    check (daily_platforms <@ array['threads', 'instagram'] and cardinality(daily_platforms) between 1 and 2);

alter table public.social_queue
  add column platform text not null default 'threads' check (platform in ('threads', 'instagram')),
  add column scheduled_at timestamptz,
  add column manual boolean not null default false,
  -- Instagram needs a picture, and only posts go there (no replies).
  add constraint social_queue_instagram_check check (platform = 'threads' or (kind = 'post' and image is not null));

-- Drafts from the agent. A post becomes one draft per daily platform (Instagram only when connected).
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
  insert into public.social_queue (kind, status, text, target_id, target_author, target_text, target_url, query, score, reason, topic, image, platform)
    select i ->> 'kind', 'draft',
      left(i ->> 'text', 500), i ->> 'target_id', left(i ->> 'target_author', 100), left(i ->> 'target_text', 1000),
      left(i ->> 'target_url', 300), left(i ->> 'query', 100), (i ->> 'score')::numeric, left(i ->> 'reason', 300),
      case when i ->> 'kind' = 'post' and p = 'threads' then cfg.post_topic end,
      case when i ->> 'kind' = 'post' and i ->> 'image' ~ '^promo/[a-z0-9-]+\.jpg$' then i ->> 'image' end,
      p
    from jsonb_array_elements(coalesce(items, '[]')) i
    cross join lateral unnest(case when i ->> 'kind' = 'post' then cfg.daily_platforms else array['threads'] end) p
    where coalesce(i ->> 'text', '') <> '' and i ->> 'kind' in ('post', 'reply', 'own_reply')
      and (p = 'threads' or (cfg.ig_token is not null and i ->> 'image' ~ '^promo/[a-z0-9-]+\.jpg$'))
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
    'queries', cfg.queries, 'voice', cfg.voice, 'post_topic', cfg.post_topic,
    'max_replies_day', cfg.max_replies_day, 'max_posts_day', cfg.max_posts_day, 'daily_platforms', cfg.daily_platforms,
    'threads_user_id', cfg.threads_user_id, 'threads_username', cfg.threads_username,
    'token', cfg.token, 'token_refreshed_at', cfg.token_refreshed_at, 'last_discovery', cfg.last_discovery,
    'ig_token', cfg.ig_token, 'ig_token_refreshed_at', cfg.ig_token_refreshed_at, 'ig_user_id', cfg.ig_user_id,
    -- Due items only: a scheduled post waits for its time.
    'approved', (select coalesce(jsonb_agg(to_jsonb(q) order by coalesce(q.scheduled_at, q.decided_at) nulls first, q.id), '[]')
                 from public.social_queue q where q.status = 'approved' and (q.scheduled_at is null or q.scheduled_at <= now())),
    'replies_today', (select count(*) from public.social_queue where kind <> 'post' and status = 'posted' and posted_at >= day_start),
    -- The daily cap is for the agent's own posts; posts the admin wrote don't count.
    'posts_today', jsonb_build_object(
      'threads', (select count(*) from public.social_queue where kind = 'post' and not manual and platform = 'threads' and status = 'posted' and posted_at >= day_start),
      'instagram', (select count(*) from public.social_queue where kind = 'post' and not manual and platform = 'instagram' and status = 'posted' and posted_at >= day_start)),
    'drafted_post_today', exists (select 1 from public.social_queue where kind = 'post' and not manual and created_at >= day_start),
    'last_reply_at', (select max(posted_at) from public.social_queue where kind <> 'post' and status = 'posted'),
    'authors_today', (select coalesce(jsonb_agg(distinct target_author), '[]') from public.social_queue
                      where kind <> 'post' and status = 'posted' and posted_at >= day_start and target_author is not null),
    'recent_posts', (select coalesce(jsonb_agg(t.text), '[]') from (select text from public.social_queue
                      where kind = 'post' and platform = 'threads' order by created_at desc limit 10) t));
end;
$$;

create or replace function public.social_cron_save(secret text, patch jsonb)
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
    ig_token = case when patch ? 'ig_token' then patch ->> 'ig_token' else ig_token end,
    ig_token_refreshed_at = case when patch ? 'ig_token' then now() else ig_token_refreshed_at end,
    ig_user_id = coalesce(patch ->> 'ig_user_id', ig_user_id),
    ig_username = coalesce(patch ->> 'ig_username', ig_username),
    last_discovery = case when patch ? 'last_discovery' then (patch ->> 'last_discovery')::timestamptz else last_discovery end,
    last_run = now(),
    last_error = case when patch ? 'last_error' then left(patch ->> 'last_error', 500) else last_error end
  where id = 1;
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
    'queries', cfg.queries, 'voice', cfg.voice, 'post_topic', cfg.post_topic, 'daily_platforms', cfg.daily_platforms,
    'max_replies_day', cfg.max_replies_day, 'max_posts_day', cfg.max_posts_day,
    'connected', cfg.token is not null, 'threads_username', cfg.threads_username,
    'token_age_days', case when cfg.token_refreshed_at is null then null else extract(day from now() - cfg.token_refreshed_at)::int end,
    'ig_connected', cfg.ig_token is not null, 'ig_username', cfg.ig_username,
    'ig_token_age_days', case when cfg.ig_token_refreshed_at is null then null else extract(day from now() - cfg.ig_token_refreshed_at)::int end,
    'last_run', cfg.last_run, 'last_discovery', cfg.last_discovery, 'last_error', cfg.last_error,
    'cron_ready', cfg.cron_secret_sha256 is not null,
    'counts', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from public.social_queue group by 1) s));
end;
$$;

-- Settings: as before, plus where the daily post goes and disconnecting Instagram.
create or replace function public.admin_social_config(patch jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  q text[];
  dp text[];
  topic text := nullif(trim(coalesce(patch ->> 'post_topic', '')), '');
begin
  perform public.require_admin();
  if patch ? 'queries' then
    select coalesce(array_agg(left(trim(x), 60)), '{}') into q from jsonb_array_elements_text(patch -> 'queries') x where trim(x) <> '';
    if cardinality(q) > 10 then raise exception 'Use at most 10 search queries'; end if;
  end if;
  if patch ? 'daily_platforms' then
    select coalesce(array_agg(distinct x), '{}') into dp from jsonb_array_elements_text(patch -> 'daily_platforms') x;
    if cardinality(dp) = 0 then raise exception 'Pick at least one place for the daily post'; end if;
    if not dp <@ array['threads', 'instagram'] then raise exception 'Unknown platform'; end if;
  end if;
  if topic ~ '[.&]' then raise exception 'Topics can''t contain . or &'; end if;
  if trim(coalesce(patch ->> 'token', '')) ~ '^[0-9a-fA-F]{32}$' then
    raise exception 'That looks like the App Secret. Paste the user access token instead (it usually starts with TH)';
  end if;
  update public.social_config set
    queries = coalesce(q, queries),
    daily_platforms = coalesce(dp, daily_platforms),
    voice = case when patch ? 'voice' then left(coalesce(patch ->> 'voice', ''), 2000) else voice end,
    post_topic = case when patch ? 'post_topic' then left(topic, 50) else post_topic end,
    max_replies_day = coalesce((patch ->> 'max_replies_day')::int, max_replies_day),
    max_posts_day = coalesce((patch ->> 'max_posts_day')::int, max_posts_day),
    token = case when patch ? 'clear_token' then null when nullif(trim(patch ->> 'token'), '') is not null then trim(patch ->> 'token') else token end,
    token_refreshed_at = case when patch ? 'clear_token' then null when nullif(trim(patch ->> 'token'), '') is not null then now() else token_refreshed_at end,
    threads_user_id = case when patch ? 'token' or patch ? 'clear_token' then null else threads_user_id end,
    threads_username = case when patch ? 'token' or patch ? 'clear_token' then null else threads_username end,
    ig_token = case when patch ? 'clear_ig_token' then null else ig_token end,
    ig_token_refreshed_at = case when patch ? 'clear_ig_token' then null else ig_token_refreshed_at end,
    ig_user_id = case when patch ? 'clear_ig_token' then null else ig_user_id end,
    ig_username = case when patch ? 'clear_ig_token' then null else ig_username end,
    last_error = case when patch ? 'token' then null else last_error end
  where id = 1;
  perform public.admin_note('social settings', null, patch - 'token');
end;
$$;

-- A post the admin wrote: one approved item per platform, now (next run) or at a set time.
create function public.admin_social_compose(platforms text[], body text, img text, at timestamptz)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  t text := trim(coalesce(body, ''));
  cfg record;
  n int;
begin
  perform public.require_admin();
  select * into cfg from public.social_config where id = 1;
  if char_length(t) not between 1 and 500 then raise exception 'Text must be 1 to 500 characters'; end if;
  if coalesce(cardinality(platforms), 0) = 0 or not platforms <@ array['threads', 'instagram'] then raise exception 'Pick Threads, Instagram or both'; end if;
  if img is not null and img !~ '^promo/[a-z0-9-]+\.jpg$' then raise exception 'Pick one of the screenshots'; end if;
  if 'instagram' = any(platforms) and img is null then raise exception 'Instagram needs a picture: pick a screenshot'; end if;
  if 'instagram' = any(platforms) and cfg.ig_token is null then raise exception 'Connect Instagram first'; end if;
  if 'threads' = any(platforms) and cfg.token is null then raise exception 'Connect Threads first'; end if;
  if at is not null and at > now() + interval '60 days' then raise exception 'Schedule at most 60 days ahead'; end if;
  insert into public.social_queue (kind, status, text, image, platform, topic, scheduled_at, manual, decided_at)
    select 'post', 'approved', t, img, p, case when p = 'threads' then cfg.post_topic end,
      case when at > now() then at end, true, now()
    from (select distinct unnest(platforms) p) x;
  get diagnostics n = row_count;
  perform public.admin_note('compose social post', null, jsonb_build_object('platforms', platforms, 'at', at));
  return n;
end;
$$;
revoke execute on function public.admin_social_compose(text[], text, text, timestamptz) from public, anon;
grant execute on function public.admin_social_compose(text[], text, text, timestamptz) to authenticated;
