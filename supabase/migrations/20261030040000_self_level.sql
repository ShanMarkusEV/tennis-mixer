-- Players set their own level; profile linking is removed.
-- A level chosen by the player is their starting point, and the games they play move it from there.
-- Players who haven't chosen one start from the advertised level of activities organizers imported, else 4.5.

drop function if exists public.link_profile(jsonb);
drop function if exists public.unlink_profile(text);
delete from public.evidence where kind in ('self_level', 'history_count');

alter table public.players add column self_level numeric check (self_level between 1 and 10);

-- The signed-in user's own level. Creates their player row if they have not claimed a name yet.
create function public.set_my_level(level numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  me uuid;
  nm text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if level is not null and (level < 1 or level > 10) then raise exception 'Level must be between 1 and 10'; end if;
  select id into me from public.players where user_id = uid and merged_into is null;
  if me is null then
    select coalesce(nullif(display_name, ''), 'Player') into nm from public.profiles where id = uid;
    insert into public.players (user_id, name) values (uid, left(coalesce(nm, 'Player'), 80)) returning id into me;
  end if;
  update public.players set self_level = round(level) where id = me;
  perform public.recompute_ratings();
  return jsonb_build_object('player_id', me);
end;
$$;
revoke execute on function public.set_my_level(numeric) from public, anon;
grant execute on function public.set_my_level(numeric) to authenticated;

-- Prior: own level if set, else imported activity levels, else 1150 (score 4.5).
create or replace function public.recompute_ratings()
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

-- Deleting an account also clears the level the user chose and their record's photo.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer set search_path = ''
as $$
declare me uuid;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  select id into me from public.players where user_id = auth.uid();
  if me is not null then
    update public.players set self_level = null, photo = null where id = me;
  end if;
  delete from auth.users where id = auth.uid();
  perform public.recompute_ratings();
end;
$$;


-- Called by the app before it logs a session. entries: [{local, pid, name, photo, att, ext: {source, id, username}}];
-- pid = the server id the app already holds for this roster entry; it wins over matching by name, so a name
-- stays attached to the same person after they claim it (their record may carry a different name).
-- att = this person is playing today. activity (optional): {source, key, level_min, level_max, date} of the
-- imported activity, credited as level evidence to everyone with att.
-- Returns {local: {pid, linked}} so the app can store ids and show who has a 10nis account.
create or replace function public.upsert_roster(entries jsonb, activity jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  e jsonb;
  pid uuid;
  local_pid uuid;
  nm text;
  photo text;
  src text;
  ext_id text;
  kid uuid;
  rid bigint;
  linked boolean;
  known uuid;
  result jsonb := '{}'::jsonb;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if jsonb_typeof(entries) <> 'array' then raise exception 'entries must be an array'; end if;
  if jsonb_array_length(entries) > 200 then raise exception 'Too many players'; end if;

  for e in select * from jsonb_array_elements(entries) loop
    nm := left(trim(e ->> 'name'), 80);
    continue when nm is null or nm = '';
    photo := nullif(e ->> 'photo', '');
    if photo is not null and photo !~ '^https://' then photo := null; end if;
    src := e #>> '{ext,source}';
    ext_id := e #>> '{ext,id}';
    kid := null; rid := null;
    if src = 'kuyy' and ext_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then kid := ext_id::uuid; end if;
    if src = 'reclub' and ext_id ~ '^[0-9]{1,15}$' then rid := ext_id::bigint; end if;

    known := null;
    if (e ->> 'pid') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      known := public.resolve_player((e ->> 'pid')::uuid);
      if not exists (select 1 from public.rosters r where r.owner_id = uid and r.player_id = known) then known := null; end if;
    end if;

    if known is not null and kid is null and rid is null then
      pid := known;
    elsif kid is not null then
      insert into public.players (kuyy_id, kuyy_username, name, photo)
        values (kid, nullif(e #>> '{ext,username}', ''), nm, photo)
        on conflict (kuyy_id) do update set
          name = case when public.players.user_id is null then excluded.name else public.players.name end,
          kuyy_username = coalesce(excluded.kuyy_username, public.players.kuyy_username),
          photo = coalesce(excluded.photo, public.players.photo)
        returning id into pid;
    elsif rid is not null then
      insert into public.players (reclub_id, reclub_username, name, photo)
        values (rid, nullif(e #>> '{ext,username}', ''), nm, photo)
        on conflict (reclub_id) do update set
          name = case when public.players.user_id is null then excluded.name else public.players.name end,
          reclub_username = coalesce(excluded.reclub_username, public.players.reclub_username),
          photo = coalesce(excluded.photo, public.players.photo)
        returning id into pid;
    else
      -- A plain name means "the person of that name on my roster": a shared row already there wins,
      -- then the organizer's own private row, else a new private row.
      select p.id into pid from public.players p
        join public.rosters r on r.player_id = p.id and r.owner_id = uid
        where lower(p.name) = lower(nm) and p.merged_into is null
        order by (p.owner_id is null) desc, p.created_at limit 1;
      if pid is null then
        select id into pid from public.players
          where owner_id = uid and lower(name) = lower(nm) and merged_into is null;
      end if;
      if pid is null then
        insert into public.players (owner_id, name, photo) values (uid, nm, photo) returning id into pid;
      elsif photo is not null then
        update public.players set photo = upsert_roster.photo where id = pid and public.players.photo is null;
      end if;
    end if;
    pid := public.resolve_player(pid);

    -- The organizer may have typed this person by hand before importing them with an id:
    -- fold that private row into the shared one so their history is not split.
    if kid is not null or rid is not null then
      select id into local_pid from public.players
        where owner_id = uid and lower(name) = lower(nm) and merged_into is null and id <> pid;
      if local_pid is not null then perform public.merge_players(local_pid, pid); end if;
    end if;

    insert into public.rosters (owner_id, player_id) values (uid, pid) on conflict do nothing;

    if activity is not null and coalesce((e ->> 'att')::boolean, true) and (activity ->> 'key') <> ''
       and (activity ->> 'level_min') is not null and (activity ->> 'source') in ('kuyy', 'reclub') then
      insert into public.evidence (player_id, kind, source, activity_key, level_min, level_max, observed_on)
        values (pid, 'activity_level', activity ->> 'source', left(activity ->> 'key', 120),
                least(10, greatest(1, (activity ->> 'level_min')::numeric)),
                least(10, greatest(1, coalesce((activity ->> 'level_max')::numeric, (activity ->> 'level_min')::numeric))),
                nullif(activity ->> 'date', '')::date)
        on conflict do nothing;
    end if;

    select user_id is not null into linked from public.players where id = pid;
    result := result || jsonb_build_object(coalesce(e ->> 'local', nm), jsonb_build_object('pid', pid, 'linked', linked));
  end loop;
  return result;
end;
$$;

