-- Match results and ratings.
-- sessions.rounds stays the source of truth; a trigger flattens every scored match into `matches`
-- (one row per court per round, player ids resolved through merged_into) and recomputes ratings.
-- Ratings are an Elo-style number replayed over all matches in date order, seeded from level evidence.

create table public.matches (
  id text primary key,                       -- session id : round : court
  session_id uuid not null references public.sessions on delete cascade,
  played_on date not null,
  seq int not null,                          -- round * 100 + court, for a stable replay order
  a uuid[] not null check (array_length(a, 1) between 1 and 2),
  b uuid[] not null check (array_length(b, 1) between 1 and 2),
  sa int not null check (sa >= 0),
  sb int not null check (sb >= 0)
);
create index matches_order_idx on public.matches (played_on, session_id, seq);
create index matches_a_idx on public.matches using gin (a);
create index matches_b_idx on public.matches using gin (b);

create table public.ratings (
  player_id uuid primary key references public.players on delete cascade,
  rating numeric not null,                   -- internal Elo scale, 800 = score 1, 1700 = score 10
  score numeric not null,                    -- 1–10, one decimal
  label text not null,
  matches int not null default 0,
  wins int not null default 0,
  games_won int not null default 0,
  games_lost int not null default 0,
  evidence int not null default 0,           -- activity-level evidence rows
  confidence text not null,
  updated_at timestamptz not null default now()
);

alter table public.matches enable row level security;   -- no policies: never read or written by clients
alter table public.ratings enable row level security;
create policy "Users read ratings of players they are, own, or host" on public.ratings
  for select to authenticated using (exists (
    select 1 from public.players p where p.id = ratings.player_id and (
      p.user_id = (select auth.uid()) or p.owner_id = (select auth.uid())
      or exists (select 1 from public.rosters r where r.player_id = p.id and r.owner_id = (select auth.uid())))));
revoke all on public.matches, public.ratings from anon;
revoke all on public.matches from authenticated;
revoke insert, update, delete on public.ratings from authenticated;

-- ---------- scale ----------
create function public.level_label(score numeric)
returns text
language sql immutable
set search_path = ''
as $$
  select case
    when score < 2.5 then 'Newbie'
    when score < 4 then 'Beginner'
    when score < 5.5 then 'Upper beginner'
    when score < 6.5 then 'Low intermediate'
    when score < 8 then 'Intermediate'
    else 'Advanced' end;
$$;

-- ---------- recompute ----------
-- Replays every match from scratch, so the result never depends on the order writes arrived in.
-- Cheap at this scale; revisit (per-player incremental) if matches ever pass ~50k rows.
create function public.recompute_ratings()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  m record;
  ra numeric; rb numeric; ea numeric; s numeric; margin numeric;
  p uuid; k numeric; cnt int;
  team_a uuid[]; team_b uuid[];
begin
  create temp table if not exists tmp_r (player_id uuid primary key, r numeric, n int, w int, gw int, gl int) on commit drop;
  truncate tmp_r;

  -- Prior from evidence: weighted mean of the level midpoints (self-declared counts double), newest 20 rows.
  -- No evidence: 1150 (score 4.5, Upper beginner), the typical social-game level.
  insert into tmp_r (player_id, r, n, w, gw, gl)
    select e.player_id, 800 + 100 * (sum(((e.level_min + e.level_max) / 2) * e.weight * case when e.kind = 'self_level' then 2 else 1 end)
             / sum(e.weight * case when e.kind = 'self_level' then 2 else 1 end) - 1), 0, 0, 0, 0
    from (select *, row_number() over (partition by player_id order by observed_on desc nulls last, id desc) rn
          from public.evidence where level_min is not null and level_max is not null) e
    where e.rn <= 20
    group by e.player_id;

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
      select tmp_r.n into cnt from tmp_r where player_id = p;
      k := greatest(16, 48 - 4 * cnt);
      update tmp_r set r = r + k * margin * (s - ea), n = n + 1, w = w + (m.sa > m.sb)::int, gw = gw + m.sa, gl = gl + m.sb where player_id = p;
    end loop;
    foreach p in array team_b loop
      select tmp_r.n into cnt from tmp_r where player_id = p;
      k := greatest(16, 48 - 4 * cnt);
      update tmp_r set r = r - k * margin * (s - ea), n = n + 1, w = w + (m.sb > m.sa)::int, gw = gw + m.sb, gl = gl + m.sa where player_id = p;
    end loop;
  end loop;

  delete from public.ratings where player_id not in (select player_id from tmp_r);
  insert into public.ratings (player_id, rating, score, label, matches, wins, games_won, games_lost, evidence, confidence, updated_at)
    select t.player_id, t.r,
           round(least(10, greatest(1, 1 + (t.r - 800) / 100)), 1),
           public.level_label(least(10, greatest(1, 1 + (t.r - 800) / 100))),
           t.n, t.w, t.gw, t.gl, ev.c,
           case when t.n >= 10 then 'established'
                when t.n >= 1 then 'based on ' || t.n || case when t.n = 1 then ' match' else ' matches' end
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

-- ---------- sessions → matches ----------
create function public.sessions_to_matches()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  pmap jsonb := '{}'::jsonb;
  pl jsonb; rd jsonb; m jsonb;
  ri int := 0; ci int;
  ta uuid[]; tb uuid[];
begin
  if tg_op = 'DELETE' then
    perform public.recompute_ratings();
    return old;
  end if;
  delete from public.matches where session_id = new.id;
  for pl in select * from jsonb_array_elements(coalesce(new.players, '[]'::jsonb)) loop
    if (pl ->> 'pid') ~* '^[0-9a-f-]{36}$' then pmap := pmap || jsonb_build_object(pl ->> 'id', pl ->> 'pid'); end if;
  end loop;
  for rd in select * from jsonb_array_elements(coalesce(new.rounds, '[]'::jsonb)) loop
    ci := 0;
    for m in select * from jsonb_array_elements(coalesce(rd -> 'matches', '[]'::jsonb)) loop
      if jsonb_typeof(m -> 'sa') = 'number' and jsonb_typeof(m -> 'sb') = 'number' then
        -- Sides whose players have no server id yet (signed-out roster) are skipped until the next sync.
        select array_agg((pmap ->> x)::uuid order by o) into ta from jsonb_array_elements_text(m -> 'a') with ordinality t(x, o);
        select array_agg((pmap ->> x)::uuid order by o) into tb from jsonb_array_elements_text(m -> 'b') with ordinality t(x, o);
        if ta is not null and tb is not null and array_position(ta, null) is null and array_position(tb, null) is null
           and array_length(ta, 1) = array_length(tb, 1) then
          insert into public.matches (id, session_id, played_on, seq, a, b, sa, sb)
            values (new.id || ':' || ri || ':' || ci, new.id, new.played_on, ri * 100 + ci, ta, tb,
                    greatest(0, (m ->> 'sa')::int), greatest(0, (m ->> 'sb')::int));
        end if;
      end if;
      ci := ci + 1;
    end loop;
    ri := ri + 1;
  end loop;
  perform public.recompute_ratings();
  return new;
end;
$$;

create trigger sessions_to_matches
  after insert or update of rounds, players, played_on or delete on public.sessions
  for each row execute function public.sessions_to_matches();

-- Merging now also moves match history.
create or replace function public.merge_players(src uuid, dst uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if src = dst or src is null or dst is null then return; end if;
  insert into public.rosters (owner_id, player_id)
    select owner_id, dst from public.rosters where player_id = src
    on conflict do nothing;
  delete from public.rosters where player_id = src;
  update public.evidence e set player_id = dst where e.player_id = src
    and not exists (select 1 from public.evidence d where d.player_id = dst and d.source = e.source and d.activity_key = e.activity_key);
  delete from public.evidence where player_id = src;
  update public.matches set a = array_replace(a, src, dst), b = array_replace(b, src, dst) where src = any(a) or src = any(b);
  update public.players set merged_into = dst, owner_id = null where id = src;
  perform public.recompute_ratings();
end;
$$;
