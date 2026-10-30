-- Tennis news: Claude finds current tennis news on the web and drafts short Threads posts with a light 10nis plug,
-- one per time slot (Jakarta times, 4 a day by default). They wait for approval like everything else; an approved
-- one goes out at its slot. Drafted every morning when news_enabled is on, or with "Generate news now" in /ad4min.

alter table public.social_config
  add column news_enabled boolean not null default false,
  add column news_slots text[] not null default array['08:00', '12:00', '17:00', '21:00']
    check (cardinality(news_slots) between 1 and 8 and array_to_string(news_slots, ',') ~ '^([01][0-9]|2[0-3]):[0-5][0-9](,([01][0-9]|2[0-3]):[0-5][0-9])*$');

alter table public.social_queue drop constraint social_queue_kind_check;
alter table public.social_queue add constraint social_queue_kind_check check (kind in ('post', 'reply', 'own_reply', 'news'));

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
  -- News is only worth posting near its slot: drafts not approved within 3 hours of it are dropped.
  update public.social_queue set status = 'skipped', error = 'Not approved before its time slot'
    where kind = 'news' and status = 'draft' and scheduled_at < now() - interval '3 hours';
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
    'replies_today', (select count(*) from public.social_queue where kind in ('reply', 'own_reply') and status = 'posted' and posted_at >= day_start),
    -- The daily cap is for the agent's own posts; posts the admin wrote don't count.
    'posts_today', jsonb_build_object(
      'threads', (select count(*) from public.social_queue where kind = 'post' and not manual and platform = 'threads' and status = 'posted' and posted_at >= day_start),
      'instagram', (select count(*) from public.social_queue where kind = 'post' and not manual and platform = 'instagram' and status = 'posted' and posted_at >= day_start)),
    'drafted_post_today', exists (select 1 from public.social_queue where kind = 'post' and not manual and created_at >= day_start),
    'last_reply_at', (select max(posted_at) from public.social_queue where kind in ('reply', 'own_reply') and status = 'posted'),
    'authors_today', (select coalesce(jsonb_agg(distinct target_author), '[]') from public.social_queue
                      where kind in ('reply', 'own_reply') and status = 'posted' and posted_at >= day_start and target_author is not null),
    'recent_posts', (select coalesce(jsonb_agg(t.text), '[]') from (select text from public.social_queue
                      where kind = 'post' and platform = 'threads' order by created_at desc limit 10) t));
end;
$$;

-- What the news step needs: settings, the next open slots (no live news item there yet) and recent headlines.
create function public.social_cron_news_state(secret text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg record;
  today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  perform public.social_require(secret);
  select * into cfg from public.social_config where id = 1;
  return jsonb_build_object(
    'enabled', cfg.news_enabled, 'voice', cfg.voice, 'connected', cfg.token is not null,
    -- The next slots from now (today and tomorrow, Jakarta time), as many as there are slots a day.
    'open_slots', (select coalesce(jsonb_agg(t order by t), '[]') from (
        select ((d + s::time) at time zone 'Asia/Jakarta') t
        from unnest(array[today, today + 1]) d, unnest(cfg.news_slots) s
        where ((d + s::time) at time zone 'Asia/Jakarta') > now() + interval '10 minutes'
        order by 1 limit cardinality(cfg.news_slots)) x
      where not exists (select 1 from public.social_queue q where q.kind = 'news' and q.status <> 'skipped' and q.scheduled_at = x.t)),
    'recent', (select coalesce(jsonb_agg(r), '[]') from (select coalesce(reason, left(text, 120)) r from public.social_queue
                where kind = 'news' and created_at > now() - interval '7 days' order by created_at desc limit 40) z));
end;
$$;

-- Add news drafts: [{text, headline, source_url, at}], only into open future slots.
create function public.social_cron_add_news(secret text, items jsonb)
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
  insert into public.social_queue (kind, status, text, reason, target_url, topic, platform, scheduled_at)
    select 'news', 'draft', left(trim(i ->> 'text'), 500), left(i ->> 'headline', 300),
      case when i ->> 'source_url' ~ '^https://' then left(i ->> 'source_url', 300) end, cfg.post_topic, 'threads', (i ->> 'at')::timestamptz
    from jsonb_array_elements(coalesce(items, '[]')) i
    where trim(coalesce(i ->> 'text', '')) <> '' and (i ->> 'at')::timestamptz > now()
      and not exists (select 1 from public.social_queue q where q.kind = 'news' and q.status <> 'skipped' and q.scheduled_at = (i ->> 'at')::timestamptz);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.social_cron_news_state(text), public.social_cron_add_news(text, jsonb) from public;
grant execute on function public.social_cron_news_state(text), public.social_cron_add_news(text, jsonb) to anon, authenticated;

-- Admin: news settings (on/off and slots), and the news list.
create function public.admin_social_news_config(enabled boolean, slots text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare s text[];
begin
  perform public.require_admin();
  select array_agg(distinct x order by x) into s from unnest(coalesce(slots, '{}')) x;
  if s is null then raise exception 'Add at least one time'; end if;
  if cardinality(s) > 8 then raise exception 'At most 8 times a day'; end if;
  if array_to_string(s, ',') !~ '^([01][0-9]|2[0-3]):[0-5][0-9](,([01][0-9]|2[0-3]):[0-5][0-9])*$' then
    raise exception 'Times look like 08:00, 12:00, 17:00';
  end if;
  update public.social_config set news_enabled = coalesce(enabled, news_enabled), news_slots = s where id = 1;
  perform public.admin_note('tennis news settings', null, jsonb_build_object('enabled', enabled, 'slots', s));
end;
$$;

create function public.admin_social_news()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'enabled', (select news_enabled from public.social_config where id = 1),
    'slots', (select news_slots from public.social_config where id = 1),
    'items', (select coalesce(jsonb_agg(to_jsonb(q) - 'creation_id' order by q.scheduled_at desc), '[]') from (
      select * from public.social_queue where kind = 'news'
        and (status in ('draft', 'approved') or created_at > now() - interval '3 days')
      order by scheduled_at desc limit 40) q));
end;
$$;
revoke execute on function public.admin_social_news_config(boolean, text[]), public.admin_social_news() from public, anon;
grant execute on function public.admin_social_news_config(boolean, text[]), public.admin_social_news() to authenticated;

-- Morning news run at 05:30 Jakarta (22:30 UTC): drafts the day's news when news_enabled is on. Its own job
-- with a longer timeout, since searching the web takes a while.
select cron.schedule('social-news', '30 22 * * *', $cron$
  select net.http_post(
    url := 'https://10nis.win/api/social/run?news=1',
    headers := jsonb_build_object('content-type', 'application/json',
      'x-cron-secret', coalesce((select decrypted_secret from vault.decrypted_secrets where name = 'social_cron_secret'), '')),
    body := '{}'::jsonb,
    timeout_milliseconds := 300000);
$cron$);
