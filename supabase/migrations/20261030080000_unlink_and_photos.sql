-- 1. Organizers can undo a wrong link (claim or player code) on their roster.
-- 2. Players can upload their own profile photo instead of their Google one.

-- ---------- unlink ----------
-- Detach a roster name from the 10nis player it was linked to. The organizer's sessions that used the name
-- are pointed at a private record again (re-deriving their matches), so those games stop counting for the
-- player. Returns the private record's id.
create function public.unlink_roster_name(roster_pid uuid, roster_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  dst uuid;
  nm text := left(coalesce(nullif(trim(roster_name), ''), 'Player'), 80);
  priv uuid;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  dst := public.resolve_player(roster_pid);
  if not exists (select 1 from public.rosters where owner_id = uid and player_id = dst) then
    raise exception 'That name is not on your roster';
  end if;
  if not exists (select 1 from public.players where id = dst and user_id is not null) then
    raise exception 'That name is not linked';
  end if;

  select id into priv from public.players where owner_id = uid and lower(name) = lower(nm) and merged_into is null;
  if priv is null then
    insert into public.players (owner_id, name) values (uid, nm) returning id into priv;
  end if;

  -- Point the organizer's logged sessions at the private record; the sessions trigger re-derives matches.
  update public.sessions se set players = (
      select jsonb_agg(case when (e ->> 'pid') ~* '^[0-9a-f-]{36}$' and public.resolve_player((e ->> 'pid')::uuid) = dst
                            then (e - 'ext') || jsonb_build_object('pid', priv, 'name', nm) else e end order by o)
      from jsonb_array_elements(se.players) with ordinality t(e, o))
    where se.user_id = uid
      and exists (select 1 from jsonb_array_elements(se.players) e
                  where (e ->> 'pid') ~* '^[0-9a-f-]{36}$' and public.resolve_player((e ->> 'pid')::uuid) = dst);

  insert into public.rosters (owner_id, player_id) values (uid, priv) on conflict do nothing;
  delete from public.rosters where owner_id = uid and player_id = dst;
  perform public.recompute_ratings();
  return priv;
end;
$$;
revoke execute on function public.unlink_roster_name(uuid, text) from public, anon;
grant execute on function public.unlink_roster_name(uuid, text) to authenticated;

-- ---------- profile photos ----------
-- Public bucket: one small image per user at avatars/<user id>/avatar.webp, resized on the phone.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('avatars', 'avatars', true, 524288, array['image/webp', 'image/jpeg', 'image/png'])
  on conflict (id) do update set public = true, file_size_limit = 524288, allowed_mime_types = array['image/webp', 'image/jpeg', 'image/png'];

create policy "Users manage their own avatar (insert)" on storage.objects
  for insert to authenticated with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users manage their own avatar (update)" on storage.objects
  for update to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users manage their own avatar (delete)" on storage.objects
  for delete to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users read their own avatar object" on storage.objects
  for select to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Set the signed-in user's photo: an image they uploaded to their own avatars folder, or null for their Google photo.
create function public.set_my_photo(url text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  me uuid;
  photo_url text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select id into me from public.players where user_id = uid and merged_into is null;
  if me is null then
    perform public.my_player_code();   -- creates the record
    select id into me from public.players where user_id = uid and merged_into is null;
  end if;
  if url is null then
    select i.photo into photo_url from public.account_identity(uid) i;
  elsif url like 'https://tuaomjxnhlwhddiucigb.supabase.co/storage/v1/object/public/avatars/' || uid::text || '/%' then
    photo_url := url;
  else
    raise exception 'Upload the photo first';
  end if;
  update public.players set photo = photo_url where id = me;
  return photo_url;
end;
$$;
revoke execute on function public.set_my_photo(text) from public, anon;
grant execute on function public.set_my_photo(text) to authenticated;
