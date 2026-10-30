-- Fix: deleting an account failed when its sessions' matches named players deleted in the same step
-- ("null value in column player_id of relation tmp_r"). The rating replay now skips players that no
-- longer exist, and matches left without a player on one side.

create or replace function public.recompute_ratings()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  m record;
  ra numeric; rb numeric; ea numeric; s numeric; margin numeric;
  p uuid; k numeric; cnt int; cur numeric; nxt numeric;
  team_a uuid[]; team_b uuid[];
begin
  create temp table if not exists tmp_r (player_id uuid primary key, r numeric, n int, w int, gw int, gl int) on commit drop;
  truncate tmp_r;
  delete from public.match_ratings where true;  -- API sessions reject a DELETE without WHERE

  insert into tmp_r (player_id, r, n, w, gw, gl)
    select pl.id, 800 + 100 * (coalesce(pl.self_level, ev.mid) - 1), 0, 0, 0, 0
    from public.players pl
    left join lateral (
      select avg((e.level_min + e.level_max) / 2) mid
      from (select * from public.evidence e where e.player_id = pl.id and e.kind = 'activity_level' and e.level_min is not null
            order by e.observed_on desc nulls last, e.id desc limit 20) e
    ) ev on true
    where pl.merged_into is null and (pl.self_level is not null or ev.mid is not null);

  for m in select * from public.matches order by played_on, session_id, seq loop
    -- Players deleted in the same statement (an account being deleted) no longer resolve: leave them out.
    team_a := array(select r from (select public.resolve_player(x) r from unnest(m.a) x) t where r is not null);
    team_b := array(select r from (select public.resolve_player(x) r from unnest(m.b) x) t where r is not null);
    if cardinality(team_a) = 0 or cardinality(team_b) = 0 then continue; end if;
    foreach p in array team_a || team_b loop
      insert into tmp_r (player_id, r, n, w, gw, gl) values (p, 1150, 0, 0, 0, 0) on conflict do nothing;
    end loop;
    if m.sa + m.sb = 0 then continue; end if;
    select avg(r) into ra from tmp_r where player_id = any(team_a);
    select avg(r) into rb from tmp_r where player_id = any(team_b);
    ea := 1 / (1 + power(10, (rb - ra) / 400));
    s := m.sa::numeric / (m.sa + m.sb);
    margin := 1 + ln(1 + abs(m.sa - m.sb)) / 3;
    -- K shrinks as a player accumulates matches: 48 at the start, floor 16.
    foreach p in array team_a loop
      select tmp_r.n, tmp_r.r into cnt, cur from tmp_r where player_id = p;
      k := greatest(16, 48 - 4 * cnt);
      nxt := cur + k * margin * (s - ea);
      update tmp_r set r = nxt, n = n + 1, w = w + (m.sa > m.sb)::int, gw = gw + m.sa, gl = gl + m.sb where player_id = p;
      insert into public.match_ratings (match_id, player_id, before, after) values (m.id, p, cur, nxt) on conflict do nothing;
    end loop;
    foreach p in array team_b loop
      select tmp_r.n, tmp_r.r into cnt, cur from tmp_r where player_id = p;
      k := greatest(16, 48 - 4 * cnt);
      nxt := cur - k * margin * (s - ea);
      update tmp_r set r = nxt, n = n + 1, w = w + (m.sb > m.sa)::int, gw = gw + m.sb, gl = gl + m.sa where player_id = p;
      insert into public.match_ratings (match_id, player_id, before, after) values (m.id, p, cur, nxt) on conflict do nothing;
    end loop;
  end loop;

  delete from public.ratings where player_id not in (select player_id from tmp_r);
  insert into public.ratings (player_id, rating, score, label, matches, wins, games_won, games_lost, evidence, confidence, updated_at)
    select t.player_id, t.r,
           round(least(10, greatest(1, 1 + (t.r - 800) / 100)), 1),
           public.level_label(least(10, greatest(1, 1 + (t.r - 800) / 100))),
           t.n, t.w, t.gw, t.gl, ev.c,
           case when t.n >= 10 then 'established from ' || t.n || ' matches'
                when t.n >= 1 and pl.self_level is not null then 'your level, adjusted by ' || t.n || case when t.n = 1 then ' match' else ' matches' end
                when t.n >= 1 then 'based on ' || t.n || case when t.n = 1 then ' match' else ' matches' end
                when pl.self_level is not null then 'set by you'
                when ev.c >= 1 then 'estimated from ' || ev.c || case when ev.c = 1 then ' activity' else ' activities' end
                else 'new' end,
           now()
    from tmp_r t
    join public.players pl on pl.id = t.player_id and pl.merged_into is null
    cross join lateral (select count(*)::int c from public.evidence e where e.player_id = t.player_id and e.kind = 'activity_level') ev
  on conflict (player_id) do update set
    rating = excluded.rating, score = excluded.score, label = excluded.label, matches = excluded.matches, wins = excluded.wins,
    games_won = excluded.games_won, games_lost = excluded.games_lost, evidence = excluded.evidence,
    confidence = excluded.confidence, updated_at = now();
end;
$$;
revoke execute on function public.recompute_ratings() from public, anon, authenticated;
