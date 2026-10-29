-- Player identity shared across sessions and organizers.
-- One players row per real person. Rows imported from Kuyy/Reclub carry that platform's id;
-- plain names an organizer typed or imported without an id are private to that organizer (owner_id).
-- A later claim or profile link fills user_id on the same row, or merges two rows (merged_into).

create table public.players (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users on delete set null,
  kuyy_id uuid unique,
  kuyy_username text,
  reclub_id bigint unique,
  reclub_username text,
  owner_id uuid references auth.users on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  photo text check (photo is null or photo ~ '^https://'),
  merged_into uuid references public.players on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index players_local_name_idx on public.players (owner_id, lower(name))
  where owner_id is not null and merged_into is null;

create trigger players_touch_updated_at
  before update on public.players
  for each row execute function public.touch_updated_at();

-- "Organizer X has player Y on a roster": lets an organizer read (and later rate) their own players.
create table public.rosters (
  owner_id uuid not null references auth.users on delete cascade,
  player_id uuid not null references public.players on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, player_id)
);
create index rosters_player_idx on public.rosters (player_id);

-- Level evidence from outside 10nis: the level of an activity someone attended, a self-declared
-- level, or a history count. Levels are on the app's 1–10 scale. activity_key dedupes the same
-- activity listed on both Kuyy and Reclub (date|hour|venue).
create table public.evidence (
  id bigserial primary key,
  player_id uuid not null references public.players on delete cascade,
  kind text not null check (kind in ('activity_level', 'self_level', 'history_count')),
  source text not null check (source in ('kuyy', 'reclub')),
  activity_key text not null,
  level_min numeric check (level_min between 1 and 10),
  level_max numeric check (level_max between 1 and 10),
  weight numeric not null default 1,
  observed_on date,
  created_at timestamptz not null default now(),
  unique (player_id, source, activity_key)
);

-- ---------- access ----------
-- Clients only read. Every write goes through the functions below, which run as the definer.
alter table public.players enable row level security;
alter table public.rosters enable row level security;
alter table public.evidence enable row level security;

create policy "Users read players they are, own, or host" on public.players
  for select to authenticated using (
    user_id = (select auth.uid())
    or owner_id = (select auth.uid())
    or exists (select 1 from public.rosters r where r.player_id = players.id and r.owner_id = (select auth.uid()))
  );
create policy "Owners read their rosters" on public.rosters
  for select to authenticated using (owner_id = (select auth.uid()));

revoke all on public.players, public.rosters, public.evidence from anon;
revoke insert, update, delete on public.players, public.rosters from authenticated;
revoke all on public.evidence from authenticated;

-- ---------- functions ----------
-- Follow merged_into to the surviving row.
create function public.resolve_player(p uuid)
returns uuid
language sql stable
set search_path = ''
as $$
  with recursive chain as (
    select id, merged_into, 1 as depth from public.players where id = p
    union all
    select pl.id, pl.merged_into, c.depth + 1 from public.players pl join chain c on pl.id = c.merged_into where c.depth < 10
  )
  select id from chain where merged_into is null limit 1;
$$;

-- Fold src into dst: rosters and evidence move over, src stays as a pointer so old ids still resolve.
create function public.merge_players(src uuid, dst uuid)
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
  update public.players set merged_into = dst, owner_id = null where id = src;
end;
$$;

-- Called by the app before it logs a session. entries: [{local, name, photo, att, ext: {source, id, username}}];
-- att = this person is playing today. activity (optional): {source, key, level_min, level_max, date} of the
-- imported activity, credited as level evidence to everyone with att.
-- Returns {local: {pid, linked}} so the app can store ids and show who has a 10nis account.
create function public.upsert_roster(entries jsonb, activity jsonb default null)
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

    if kid is not null then
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

revoke execute on function public.upsert_roster(jsonb, jsonb) from public, anon;
grant execute on function public.upsert_roster(jsonb, jsonb) to authenticated;
revoke execute on function public.merge_players(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.resolve_player(uuid) from public, anon;
