-- The game rating also counts the player's own diary: every game in a finished play session moves their rating,
-- the same weight as a mabar match. The opponent is unknown, so it is taken to be at the player's own level
-- (expected result 0.5). A logged score sets the result and the margin; without one a win counts like 6-4.
-- Mabar matches and diary games are replayed together in time order.

-- Rating before and after each finished play session, for the summary page.
create table public.play_ratings (
  play_id uuid primary key references public.plays on delete cascade,
  player_id uuid not null references public.players on delete cascade,
  before numeric not null,
  after numeric not null
);
alter table public.play_ratings enable row level security;
create policy "Users read ratings of own plays" on public.play_ratings
  for select to authenticated using (exists (select 1 from public.plays p where p.id = play_id and p.user_id = (select auth.uid())));
revoke all on public.play_ratings from anon;
revoke insert, update, delete on public.play_ratings from authenticated;
grant select on public.play_ratings to authenticated;   -- rows still limited by the policy above

create or replace function public.recompute_ratings()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev record;
  ra numeric; rb numeric; ea numeric; s numeric; margin numeric;
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
           null::text as res, null::int as me, null::int as opp
      from public.matches m
    union all
    select 1, null, pl.id, pl.user_id, (pl.started_at at time zone 'Asia/Jakarta') + make_interval(secs => x.o::int),
           null::uuid[], null::uuid[], null::int, null::int,
           x.j ->> 'res',
           case when (x.j ->> 'me') ~ '^\d{1,2}$' then (x.j ->> 'me')::int end,
           case when (x.j ->> 'opp') ~ '^\d{1,2}$' then (x.j ->> 'opp')::int end
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
      k := greatest(16, 48 - 4 * cnt);
      nxt := cur + k * margin * (s - 0.5);
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

-- A finished (or reopened, edited or deleted finished) play session updates the ratings. A diary player needs a
-- player record to have a rating, so one is made for them (named from their profile, else "Player").
create function public.plays_to_ratings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'DELETE' and new.ended_at is not null
     and not exists (select 1 from public.players where user_id = new.user_id and merged_into is null) then
    insert into public.players (user_id, name)
      values (new.user_id, left(coalesce((select nullif(trim(display_name), '') from public.profiles where id = new.user_id), 'Player'), 80))
      on conflict do nothing;
  end if;
  if (tg_op = 'DELETE' and old.ended_at is not null)
     or (tg_op <> 'DELETE' and new.ended_at is not null)
     or (tg_op = 'UPDATE' and old.ended_at is not null) then
    perform public.recompute_ratings();
  end if;
  return null;
end;
$$;
create trigger plays_to_ratings
  after insert or update of games, ended_at, started_at or delete on public.plays
  for each row execute function public.plays_to_ratings();

-- Diary sessions finished before this migration: give their players a record, then replay everything.
insert into public.players (user_id, name)
  select distinct p.user_id, left(coalesce((select nullif(trim(pr.display_name), '') from public.profiles pr where pr.id = p.user_id), 'Player'), 80)
  from public.plays p
  where p.ended_at is not null and not exists (select 1 from public.players x where x.user_id = p.user_id and x.merged_into is null)
on conflict do nothing;
select public.recompute_ratings();
