-- Fix: saving a roster failed ("missing FROM-clause entry for table upsert_roster") when a plain name that
-- already exists as the organizer's private player came with a photo. The local variable "photo" was
-- referenced as upsert_roster.photo, which only works for parameters. Renamed to v_photo.

-- Called by the app before it logs a session. entries: [{local, pid, name, photo, att, ext: {source, id, username}}];
-- pid = the server id the app already holds for this roster entry; it wins over matching by name, so a name
-- stays attached to the same person after they claim it (their record may carry a different name).
-- att = this person is playing today. activity (optional): {source, key, level_min, level_max, date} of the
-- imported activity, credited as level evidence to everyone with att.
-- Returns {local: {pid, linked, name, photo}}: name and photo are the account's, for linked players.
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
  v_photo text;
  src text;
  ext_id text;
  kid uuid;
  rid bigint;
  linked boolean;
  acct record;
  known uuid;
  result jsonb := '{}'::jsonb;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if jsonb_typeof(entries) <> 'array' then raise exception 'entries must be an array'; end if;
  if jsonb_array_length(entries) > 200 then raise exception 'Too many players'; end if;

  for e in select * from jsonb_array_elements(entries) loop
    nm := left(trim(e ->> 'name'), 80);
    continue when nm is null or nm = '';
    v_photo := nullif(e ->> 'photo', '');
    if v_photo is not null and v_photo !~ '^https://' then v_photo := null; end if;
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
        values (kid, nullif(e #>> '{ext,username}', ''), nm, v_photo)
        on conflict (kuyy_id) do update set
          name = case when public.players.user_id is null then excluded.name else public.players.name end,
          kuyy_username = coalesce(excluded.kuyy_username, public.players.kuyy_username),
          photo = coalesce(excluded.photo, public.players.photo)
        returning id into pid;
    elsif rid is not null then
      insert into public.players (reclub_id, reclub_username, name, photo)
        values (rid, nullif(e #>> '{ext,username}', ''), nm, v_photo)
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
        insert into public.players (owner_id, name, photo) values (uid, nm, v_photo) returning id into pid;
      elsif v_photo is not null then
        update public.players pl set photo = v_photo where pl.id = pid and pl.photo is null;
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

    select pr.user_id is not null as linked, pr.name, pr.photo into acct from public.players pr where pr.id = pid;
    result := result || jsonb_build_object(coalesce(e ->> 'local', nm), case when acct.linked
      then jsonb_build_object('pid', pid, 'linked', true, 'name', acct.name, 'photo', acct.photo)
      else jsonb_build_object('pid', pid, 'linked', false) end);
  end loop;
  return result;
end;
$$;
