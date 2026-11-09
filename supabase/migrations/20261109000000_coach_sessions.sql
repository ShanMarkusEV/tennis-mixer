-- Catatan coaching (coaching journal), 0.11: after a coaching session, the player notes what was practised (the
-- diary's tags), the coach's cue words, homework (PR) and a target for next time. Written by the student only;
-- the coach is just a name. Private to its owner, like the play diary. Not part of the rating. (Events keep the early name les_save / les_pr.)

create table public.coach_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  held_on date not null default ((now() at time zone 'Asia/Jakarta')::date),
  coach text check (char_length(coach) <= 80),
  place text check (char_length(place) <= 120),
  topics text[] check (topics is null or cardinality(topics) <= 3),
  cues text[] check (cues is null or (cardinality(cues) <= 2 and char_length(array_to_string(cues, '')) <= 240)),
  homework text check (char_length(homework) <= 280),
  target text check (char_length(target) <= 280),
  feel smallint check (feel between 1 and 3),
  note text check (char_length(note) <= 500),
  pr_tries int not null default 0 check (pr_tries between 0 and 999),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index coach_sessions_user_held_idx on public.coach_sessions (user_id, held_on desc);

alter table public.coach_sessions enable row level security;
create policy "Users read own coach sessions" on public.coach_sessions
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users create own coach sessions" on public.coach_sessions
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users update own coach sessions" on public.coach_sessions
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Users delete own coach sessions" on public.coach_sessions
  for delete to authenticated using ((select auth.uid()) = user_id);
revoke all on public.coach_sessions from anon;

create trigger coach_sessions_touch_updated_at
  before update on public.coach_sessions
  for each row execute function public.touch_updated_at();

-- Guest merge also moves the coaching journal.
create or replace function public.finish_guest_merge(t text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  g uuid;
  r record;
  d uuid;
  gp uuid;
  mp uuid;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  delete from public.guest_merges where token = t and expires_at > now() returning guest_id into g;
  if g is null or g = uid then return null; end if;
  if not coalesce((select is_anonymous from auth.users where id = g), false) then return null; end if;

  update public.sessions set user_id = uid where user_id = g;
  update public.session_shares set owner_id = uid where owner_id = g;
  update public.feedback set user_id = uid where user_id = g;
  update public.plays set user_id = uid where user_id = g;
  update public.coach_sessions set user_id = uid where user_id = g;
  update public.profiles set weak_tags = coalesce(public.profiles.weak_tags, (select weak_tags from public.profiles where id = g))
    where id = uid;

  for r in select id, name from public.players where owner_id = g and merged_into is null loop
    select id into d from public.players where owner_id = uid and lower(name) = lower(r.name) and merged_into is null;
    if d is not null then perform public.merge_players(r.id, d);
    else update public.players set owner_id = uid where id = r.id; end if;
  end loop;
  insert into public.rosters (owner_id, player_id) select uid, player_id from public.rosters where owner_id = g
    on conflict do nothing;
  delete from public.rosters where owner_id = g;

  select id into gp from public.players where user_id = g and merged_into is null;
  if gp is not null then
    select id into mp from public.players where user_id = uid and merged_into is null;
    if mp is null then
      update public.players set user_id = uid where id = gp;
    else
      update public.players set user_id = null where id = gp;
      update public.players set self_level = coalesce(public.players.self_level, (select self_level from public.players where id = gp)) where id = mp;
      perform public.merge_players(gp, mp);
    end if;
  end if;

  delete from auth.users where id = g;
  perform public.recompute_ratings();
  return g;
end;
$$;
revoke execute on function public.finish_guest_merge(text) from public, anon;
grant execute on function public.finish_guest_merge(text) to authenticated;

-- Idle guests: a guest with a coaching note has kept something.
create or replace function public.purge_idle_guests()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare n int;
begin
  delete from auth.users u where u.is_anonymous and u.created_at < now() - interval '30 days'
    and not exists (select 1 from public.sessions s where s.user_id = u.id)
    and not exists (select 1 from public.plays p where p.user_id = u.id)
    and not exists (select 1 from public.coach_sessions c where c.user_id = u.id)
    and not exists (select 1 from public.rosters r where r.owner_id = u.id)
    and not exists (select 1 from public.players p where p.user_id = u.id);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.purge_idle_guests() from public, anon, authenticated;

-- ---------- usage events ----------
alter table public.events drop constraint events_event_check;
alter table public.events add constraint events_event_check check (event in (
  'open', 'round', 'finish', 'import', 'signin', 'install', 'error', 'join',
  'guest', 'linked', 'merged', 'open_outside', 'latihan', 'share_latihan',
  'onboard', 'play_start', 'play_game', 'play_end', 'play_share', 'les_save', 'les_pr'));

create or replace function public.track(device text, event text, props jsonb default '{}', signed_in boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if device !~ '^[0-9a-f]{16}$' or event not in ('open', 'round', 'finish', 'import', 'signin', 'install', 'error', 'join',
      'guest', 'linked', 'merged', 'open_outside', 'latihan', 'share_latihan',
      'onboard', 'play_start', 'play_game', 'play_end', 'play_share', 'les_save', 'les_pr') then return; end if;
  -- Ignore floods from one device (more than 500 events in a day).
  if (select count(*) from public.events e where e.device = track.device and e.created_at > now() - interval '1 day') >= 500 then return; end if;
  insert into public.events (device, event, signed_in, props)
    values (device, event, coalesce(signed_in, false),
            case when jsonb_typeof(props) = 'object' and pg_column_size(props) < 512 then props else '{}' end);
end;
$$;

-- ---------- admin: the play diary, plus the coaching journal ----------
create or replace function public.admin_play_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare jkt date := (now() at time zone 'Asia/Jakarta')::date;
begin
  perform public.require_admin();
  return (
    with fin as (select * from public.plays where ended_at is not null),
    g as (select p.user_id, p.started_at, x.j from public.plays p cross join lateral jsonb_array_elements(p.games) as x(j)),
    -- Every tag, from a session or from one of its games, with when its session started.
    tags as (
      select p.started_at, 'good' as kind, t.tag from public.plays p cross join lateral unnest(coalesce(p.good, '{}')) as t(tag)
      union all select p.started_at, 'bad', t.tag from public.plays p cross join lateral unnest(coalesce(p.bad, '{}')) as t(tag)
      union all select g.started_at, 'good', t.tag from g cross join lateral jsonb_array_elements_text(coalesce(g.j -> 'good', '[]')) as t(tag)
      union all select g.started_at, 'bad', t.tag from g cross join lateral jsonb_array_elements_text(coalesce(g.j -> 'bad', '[]')) as t(tag)),
    cs as (select * from public.coach_sessions),
    per_user as (select user_id, count(*) as n from fin group by user_id),
    ev as (select e.event, e.device from public.events e where e.created_at > now() - interval '30 days')
    select jsonb_build_object(
      'finished', (select count(*) from fin),
      'finished_7d', (select count(*) from fin where ended_at > now() - interval '7 days'),
      'open', (select count(*) from public.plays where ended_at is null),
      'players', (select count(*) from per_user),
      'players_7d', (select count(distinct user_id) from fin where ended_at > now() - interval '7 days'),
      'returning', (select count(*) from per_user where n >= 2),
      'sessions_3plus', (select count(*) from fin where jsonb_array_length(games) >= 3),
      'doubles', (select count(*) from fin where format = 'double'),
      'sessions_tagged', (select count(*) from fin f where cardinality(coalesce(f.good, '{}')) + cardinality(coalesce(f.bad, '{}')) > 0
        or exists (select 1 from jsonb_array_elements(f.games) x(j)
                   where jsonb_array_length(coalesce(x.j -> 'good', '[]')) + jsonb_array_length(coalesce(x.j -> 'bad', '[]')) > 0)),
      'sessions_noted', (select count(*) from fin where coalesce(lesson, '') <> ''),
      'games', (select count(*) from g),
      'wins', (select count(*) from g where g.j ->> 'res' = 'W'),
      'games_tagged', (select count(*) from g where jsonb_array_length(coalesce(g.j -> 'good', '[]')) + jsonb_array_length(coalesce(g.j -> 'bad', '[]')) > 0),
      'games_scored', (select count(*) from g where g.j ->> 'me' is not null),
      'games_noted', (select count(*) from g where coalesce(g.j ->> 'note', '') <> ''),
      'lessons', (select count(*) from fin where coalesce(lesson, '') <> ''),
      'shares', (select count(*) from public.events where event = 'play_share'),
      'les', (select count(*) from cs),
      'les_7d', (select count(*) from cs where created_at > now() - interval '7 days'),
      'les_players', (select count(distinct user_id) from cs),
      'les_pr_tries', (select coalesce(sum(pr_tries), 0) from cs),
      'les_topics_30d', (select coalesce(jsonb_agg(jsonb_build_object('tag', z.tag, 'n', z.n) order by z.n desc), '[]')
        from (select t.tag, count(*) as n from cs cross join lateral unnest(coalesce(cs.topics, '{}')) as t(tag)
              where cs.held_on > (now() at time zone 'Asia/Jakarta')::date - 30 group by t.tag) z),
      'bad_30d', (select coalesce(jsonb_agg(jsonb_build_object('tag', z.tag, 'n', z.n) order by z.n desc), '[]')
        from (select tag, count(*) as n from tags where kind = 'bad' and started_at > now() - interval '30 days' group by tag) z),
      'good_30d', (select coalesce(jsonb_agg(jsonb_build_object('tag', z.tag, 'n', z.n) order by z.n desc), '[]')
        from (select tag, count(*) as n from tags where kind = 'good' and started_at > now() - interval '30 days' group by tag) z),
      'funnel_30d', jsonb_build_object(
        'open', (select count(distinct device) from ev where event = 'open'),
        'onboard', (select count(distinct device) from ev where event = 'onboard'),
        'play_start', (select count(distinct device) from ev where event = 'play_start'),
        'play_game', (select count(distinct device) from ev where event = 'play_game'),
        'play_end', (select count(distinct device) from ev where event = 'play_end'),
        'play_share', (select count(distinct device) from ev where event = 'play_share')),
      'daily', (select jsonb_agg(jsonb_build_object('day', d.day,
          'plays', (select count(*) from public.plays p where (p.started_at at time zone 'Asia/Jakarta')::date = d.day),
          'games', (select count(*) from g where (g.started_at at time zone 'Asia/Jakarta')::date = d.day)) order by d.day)
        from (select generate_series(jkt - 29, jkt, interval '1 day')::date as day) d)));
end;
$$;
