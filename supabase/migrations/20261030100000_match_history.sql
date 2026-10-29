-- Match history for players: each player can list the matches linked to them (in anyone's sessions),
-- with partners, opponents, the score and how their level moved. Only their own matches are returned.

-- Level before/after every match, written by the rating replay (rebuilt on every recompute).
create table public.match_ratings (
  match_id text not null references public.matches on delete cascade,
  player_id uuid not null references public.players on delete cascade,
  before numeric not null,
  after numeric not null,
  primary key (match_id, player_id)
);
create index match_ratings_player_idx on public.match_ratings (player_id);
alter table public.match_ratings enable row level security;   -- read only through my_matches()
revoke all on public.match_ratings from anon, authenticated;

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
    team_a := array(select public.resolve_player(x) from unnest(m.a) x);
    team_b := array(select public.resolve_player(x) from unnest(m.b) x);
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

-- The signed-in player's matches, newest session first, grouped by session. Scores are on the 1–10 scale.
create function public.my_matches(max_sessions int default 30)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with me as (
    select id from public.players where user_id = auth.uid() and merged_into is null
  ),
  mine as (
    select m.*, se.user_id host_id, se.mode, se.created_at,
           array(select public.resolve_player(x) from unnest(m.a) x) ra,
           array(select public.resolve_player(x) from unnest(m.b) x) rb
    from public.matches m join public.sessions se on se.id = m.session_id
  ),
  rows as (
    select mi.*, me.id me_id, (me.id = any(mi.ra)) on_a, mr.before, mr.after
    from mine mi cross join me
    left join public.match_ratings mr on mr.match_id = mi.id and mr.player_id = me.id
    where me.id = any(mi.ra) or me.id = any(mi.rb)
  ),
  named as (
    select r.*,
      array(select coalesce(pl.name, '?') from unnest(case when r.on_a then r.ra else r.rb end) with ordinality t(x, o)
            left join public.players pl on pl.id = t.x where t.x <> r.me_id order by o) partners,
      array(select coalesce(pl.name, '?') from unnest(case when r.on_a then r.rb else r.ra end) with ordinality t(x, o)
            left join public.players pl on pl.id = t.x order by o) opponents,
      case when r.on_a then r.sa else r.sb end mine_score,
      case when r.on_a then r.sb else r.sa end their_score
    from rows r
  ),
  sessions as (
    select n.session_id, n.played_on, n.created_at, n.host_id, n.mode,
      jsonb_agg(jsonb_build_object(
        'partners', to_jsonb(n.partners), 'opponents', to_jsonb(n.opponents),
        'mine', n.mine_score, 'theirs', n.their_score,
        'before', round(least(10, greatest(1, 1 + (n.before - 800) / 100)), 1),
        'after', round(least(10, greatest(1, 1 + (n.after - 800) / 100)), 1)) order by n.seq) matches,
      (array_agg(n.before order by n.seq))[1] first_before,
      (array_agg(n.after order by n.seq desc))[1] last_after
    from named n
    group by n.session_id, n.played_on, n.created_at, n.host_id, n.mode
    order by n.played_on desc, n.created_at desc
    limit greatest(1, least(max_sessions, 100))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'played_on', s.played_on, 'mode', s.mode,
      'host', case when s.host_id = auth.uid() then null
                   else coalesce((select name from public.players where user_id = s.host_id and merged_into is null),
                                 (select i.name from public.account_identity(s.host_id) i)) end,
      'before', round(least(10, greatest(1, 1 + (s.first_before - 800) / 100)), 1),
      'after', round(least(10, greatest(1, 1 + (s.last_after - 800) / 100)), 1),
      'matches', s.matches) order by s.played_on desc, s.created_at desc), '[]'::jsonb)
  from sessions s;
$$;
revoke execute on function public.my_matches(int) from public, anon;
grant execute on function public.my_matches(int) to authenticated;

select public.recompute_ratings();
