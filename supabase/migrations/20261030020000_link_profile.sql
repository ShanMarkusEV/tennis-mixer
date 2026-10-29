-- Linking a 10nis account to the user's own Kuyy/Reclub profile.
-- The signed-in user becomes the owner (user_id) of the players row for that profile. If organizers already
-- imported the person, that row (with its match history) is claimed; if the user already has a row from
-- another link or claim, the two are merged. Their past activities become level evidence.

create function public.link_profile(profile jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  src text := profile ->> 'source';
  ext_id text := profile ->> 'id';
  kid uuid; rid bigint;
  me uuid; ext uuid; ext_user uuid;
  nm text := left(nullif(trim(profile ->> 'name'), ''), 80);
  v_photo text := nullif(profile ->> 'photo', '');
  h jsonb;
  added int := 0;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if src = 'kuyy' and ext_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then kid := ext_id::uuid;
  elsif src = 'reclub' and ext_id ~ '^[0-9]{1,15}$' then rid := ext_id::bigint;
  else raise exception 'Unrecognised profile';
  end if;
  if v_photo is not null and v_photo !~ '^https://' then v_photo := null; end if;

  select id into me from public.players where user_id = uid and merged_into is null;
  select id into ext from public.players where (kid is not null and kuyy_id = kid) or (rid is not null and reclub_id = rid);
  if ext is not null then
    ext := public.resolve_player(ext);
    select user_id into ext_user from public.players where id = ext;
    if ext_user is not null and ext_user <> uid then
      raise exception 'This profile is already linked to another 10nis account';
    end if;
  end if;

  if me is null and ext is null then
    insert into public.players (user_id, name, photo) values (uid, coalesce(nm, 'Player'), v_photo) returning id into me;
  elsif me is null then
    update public.players set user_id = uid, owner_id = null where id = ext;
    me := ext;
  elsif ext is not null and ext <> me then
    -- Free the external id on the old row first: it is unique and is about to move to `me`.
    update public.players set kuyy_id = case when kid is not null then null else kuyy_id end,
                              reclub_id = case when rid is not null then null else reclub_id end where id = ext;
    perform public.merge_players(ext, me);
  end if;

  update public.players set
    kuyy_id = coalesce(kid, kuyy_id),
    kuyy_username = case when kid is not null then nullif(profile ->> 'username', '') else kuyy_username end,
    reclub_id = coalesce(rid, reclub_id),
    reclub_username = case when rid is not null then nullif(profile ->> 'username', '') else reclub_username end,
    photo = coalesce(public.players.photo, v_photo)
  where id = me;

  for h in select * from jsonb_array_elements(coalesce(profile -> 'history', '[]'::jsonb)) limit 200 loop
    if (h ->> 'key') <> '' and (h ->> 'level_min') is not null then
      insert into public.evidence (player_id, kind, source, activity_key, level_min, level_max, observed_on)
        values (me, 'activity_level', src, left(h ->> 'key', 120),
                least(10, greatest(1, (h ->> 'level_min')::numeric)),
                least(10, greatest(1, coalesce((h ->> 'level_max')::numeric, (h ->> 'level_min')::numeric))),
                nullif(h ->> 'date', '')::date)
        on conflict do nothing;
      if found then added := added + 1; end if;
    end if;
  end loop;
  insert into public.evidence (player_id, kind, source, activity_key, weight, observed_on)
    values (me, 'history_count', src, 'count', greatest(0, coalesce((profile #>> '{counts,joined}')::numeric, 0)), current_date)
    on conflict (player_id, source, activity_key) do update set weight = excluded.weight, observed_on = excluded.observed_on;

  perform public.recompute_ratings();
  return jsonb_build_object('player_id', me, 'added', added);
end;
$$;
revoke execute on function public.link_profile(jsonb) from public, anon;
grant execute on function public.link_profile(jsonb) to authenticated;

-- Remove one linked platform from the user's own player row, with the history it brought in.
create function public.unlink_profile(src text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare me uuid;
begin
  select id into me from public.players where user_id = auth.uid() and merged_into is null;
  if me is null then return; end if;
  if src = 'kuyy' then update public.players set kuyy_id = null, kuyy_username = null where id = me;
  elsif src = 'reclub' then update public.players set reclub_id = null, reclub_username = null where id = me;
  else raise exception 'Unknown source';
  end if;
  -- Organizers' imports re-add evidence for activities they hosted on their next sync.
  delete from public.evidence where player_id = me and source = src;
  perform public.recompute_ratings();
end;
$$;
revoke execute on function public.unlink_profile(text) from public, anon;
grant execute on function public.unlink_profile(text) to authenticated;

-- Deleting an account also drops the level evidence and platform links on the user's player row.
-- The row itself stays (unclaimed) because other organizers' logged sessions refer to it.
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
    delete from public.evidence where player_id = me;
    update public.players set kuyy_id = null, kuyy_username = null, reclub_id = null, reclub_username = null, photo = null where id = me;
  end if;
  delete from auth.users where id = auth.uid();
  perform public.recompute_ratings();
end;
$$;
