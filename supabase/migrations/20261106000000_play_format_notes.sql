-- Play diary, from 0.10: a session is singles or doubles, and what went well / badly is noted once per session
-- instead of after every game (logging a game is just the result and an optional score). The session note is
-- the existing `lesson` column. Older sessions keep their per-game tags; both are counted.
-- Rating: a doubles loss moves the rating half as much (part of it is the partner's); wins count the same.

alter table public.plays add column format text not null default 'single' check (format in ('single', 'double'));
alter table public.plays add column good text[] check (good is null or cardinality(good) <= 3);
alter table public.plays add column bad text[] check (bad is null or cardinality(bad) <= 3);

create or replace function public.recompute_ratings()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev record;
  ra numeric; rb numeric; ea numeric; s numeric; margin numeric; f numeric;
  p uuid; gp uuid; k numeric; cnt int; cur numeric; nxt numeric;
  team_a uuid[]; team_b uuid[];
begin
  create temp table if not exists tmp_r (player_id uuid primary key, r numeric, n int, w int, gw int, gl int) on commit drop;
  truncate tmp_r;
  delete from public.match_ratings where true;  -- API sessions reject a DELETE without WHERE
  delete from public.play_ratings where true;

  insert into tmp_r (player_id, r, n, w, gw, gl)
    select pl.id, 800 + 100 * (coalesce(pl.self_level, ev2.mid) - 1), 0, 0, 0, 0
    from public.players pl
    left join lateral (
      select avg((e.level_min + e.level_max) / 2) mid
      from (select * from public.evidence e where e.player_id = pl.id and e.kind = 'activity_level' and e.level_min is not null
            order by e.observed_on desc nulls last, e.id desc limit 20) e
    ) ev2 on true
    where pl.merged_into is null and (pl.self_level is not null or ev2.mid is not null);

  for ev in
    select 0 as kind, m.id as mid, null::uuid as play_id, null::uuid as uid,
           m.played_on::timestamp + make_interval(secs => m.seq) as at, m.a, m.b, m.sa, m.sb,
           null::text as res, null::int as me, null::int as opp, null::text as fmt
      from public.matches m
    union all
    select 1, null, pl.id, pl.user_id, (pl.started_at at time zone 'Asia/Jakarta') + make_interval(secs => x.o::int),
           null::uuid[], null::uuid[], null::int, null::int,
           x.j ->> 'res',
           case when (x.j ->> 'me') ~ '^\d{1,2}$' then (x.j ->> 'me')::int end,
           case when (x.j ->> 'opp') ~ '^\d{1,2}$' then (x.j ->> 'opp')::int end,
           pl.format
      from public.plays pl cross join lateral jsonb_array_elements(pl.games) with ordinality as x(j, o)
      where pl.ended_at is not null and x.j ->> 'res' in ('W', 'L')
    order by 5, 1, 2
  loop
    if ev.kind = 0 then
      -- A mabar match, as before.
      team_a := array(select r from (select public.resolve_player(x) r from unnest(ev.a) x) t where r is not null);
      team_b := array(select r from (select public.resolve_player(x) r from unnest(ev.b) x) t where r is not null);
      if cardinality(team_a) = 0 or cardinality(team_b) = 0 then continue; end if;
      foreach p in array team_a || team_b loop
        insert into tmp_r (player_id, r, n, w, gw, gl) values (p, 1150, 0, 0, 0, 0) on conflict do nothing;
      end loop;
      if ev.sa + ev.sb = 0 then continue; end if;
      select avg(r) into ra from tmp_r where player_id = any(team_a);
      select avg(r) into rb from tmp_r where player_id = any(team_b);
      ea := 1 / (1 + power(10, (rb - ra) / 400));
      s := ev.sa::numeric / (ev.sa + ev.sb);
      margin := 1 + ln(1 + abs(ev.sa - ev.sb)) / 3;
      -- K shrinks as a player accumulates games: 48 at the start, floor 16.
      foreach p in array team_a loop
        select tmp_r.n, tmp_r.r into cnt, cur from tmp_r where player_id = p;
        k := greatest(16, 48 - 4 * cnt);
        nxt := cur + k * margin * (s - ea);
        update tmp_r set r = nxt, n = n + 1, w = w + (ev.sa > ev.sb)::int, gw = gw + ev.sa, gl = gl + ev.sb where player_id = p;
        insert into public.match_ratings (match_id, player_id, before, after) values (ev.mid, p, cur, nxt) on conflict do nothing;
      end loop;
      foreach p in array team_b loop
        select tmp_r.n, tmp_r.r into cnt, cur from tmp_r where player_id = p;
        k := greatest(16, 48 - 4 * cnt);
        nxt := cur - k * margin * (s - ea);
        update tmp_r set r = nxt, n = n + 1, w = w + (ev.sb > ev.sa)::int, gw = gw + ev.sb, gl = gl + ev.sa where player_id = p;
        insert into public.match_ratings (match_id, player_id, before, after) values (ev.mid, p, cur, nxt) on conflict do nothing;
      end loop;
    else
      -- A diary game: against an opponent at the player's own level.
      select id into gp from public.players where user_id = ev.uid and merged_into is null;
      if gp is null then continue; end if;
      insert into tmp_r (player_id, r, n, w, gw, gl) values (gp, 1150, 0, 0, 0, 0) on conflict do nothing;
      select tmp_r.n, tmp_r.r into cnt, cur from tmp_r where player_id = gp;
      if ev.me is not null and ev.opp is not null and ev.me <> ev.opp and (ev.me > ev.opp) = (ev.res = 'W') then
        s := ev.me::numeric / (ev.me + ev.opp);
        margin := 1 + ln(1 + abs(ev.me - ev.opp)) / 3;
      else
        s := case when ev.res = 'W' then 0.6 else 0.4 end;   -- like 6-4
        margin := 1 + ln(3) / 3;
      end if;
      -- Doubles: a loss counts half, since part of it is the partner's. A win counts in full.
      f := case when ev.fmt = 'double' and ev.res = 'L' then 0.5 else 1 end;
      k := greatest(16, 48 - 4 * cnt);
      nxt := cur + k * margin * (s - 0.5) * f;
      update tmp_r set r = nxt, n = n + 1, w = w + (ev.res = 'W')::int,
        gw = gw + coalesce(ev.me, 0), gl = gl + coalesce(ev.opp, 0) where player_id = gp;
      insert into public.play_ratings (play_id, player_id, before, after) values (ev.play_id, gp, cur, nxt)
        on conflict (play_id) do update set after = excluded.after;
    end if;
  end loop;

  delete from public.ratings where player_id not in (select player_id from tmp_r);
  insert into public.ratings (player_id, rating, score, label, matches, wins, games_won, games_lost, evidence, confidence, updated_at)
    select t.player_id, t.r,
           round(least(10, greatest(1, 1 + (t.r - 800) / 100)), 1),
           public.level_label(least(10, greatest(1, 1 + (t.r - 800) / 100))),
           t.n, t.w, t.gw, t.gl, ev3.c,
           case when t.n >= 10 then 'established from ' || t.n || ' games'
                when t.n >= 1 and pl.self_level is not null then 'your level, adjusted by ' || t.n || case when t.n = 1 then ' game' else ' games' end
                when t.n >= 1 then 'based on ' || t.n || case when t.n = 1 then ' game' else ' games' end
                when pl.self_level is not null then 'set by you'
                when ev3.c >= 1 then 'estimated from ' || ev3.c || case when ev3.c = 1 then ' activity' else ' activities' end
                else 'new' end,
           now()
    from tmp_r t
    join public.players pl on pl.id = t.player_id and pl.merged_into is null
    cross join lateral (select count(*)::int c from public.evidence e where e.player_id = t.player_id and e.kind = 'activity_level') ev3
  on conflict (player_id) do update set
    rating = excluded.rating, score = excluded.score, label = excluded.label, matches = excluded.matches, wins = excluded.wins,
    games_won = excluded.games_won, games_lost = excluded.games_lost, evidence = excluded.evidence,
    confidence = excluded.confidence, updated_at = now();
end;
$$;
revoke execute on function public.recompute_ratings() from public, anon, authenticated;

-- Switching a finished session between singles and doubles changes the rating too.
drop trigger plays_to_ratings on public.plays;
create trigger plays_to_ratings
  after insert or update of games, ended_at, started_at, format or delete on public.plays
  for each row execute function public.plays_to_ratings();

-- ---------- admin: the play diary ----------
-- Tags now come from the session (good / bad) as well as from games logged before 0.10.
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

select public.recompute_ratings();
