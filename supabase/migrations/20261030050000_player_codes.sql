-- Player codes: every 10nis player can show a short code (or its QR) so an organizer links a name on their
-- roster to that player directly, without the player doing anything at the court. Showing the code is the
-- player's consent; knowing it only reveals their name and photo.

alter table public.players add column code text unique check (code ~ '^[A-Z2-9]{6}$');

-- The signed-in user's code, created on first use (along with their player record if they have none).
create function public.my_player_code()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  me uuid;
  c text;
  nm text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select id, code into me, c from public.players where user_id = uid and merged_into is null;
  if me is null then
    select coalesce(nullif(display_name, ''), 'Player') into nm from public.profiles where id = uid;
    insert into public.players (user_id, name) values (uid, left(coalesce(nm, 'Player'), 80)) returning id into me;
  end if;
  while c is null loop
    -- No 0/O, 1/I/L: easy to read out and type.
    c := (select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '') from generate_series(1, 6));
    begin
      update public.players set code = c where id = me;
    exception when unique_violation then
      c := null;
    end;
  end loop;
  return c;
end;
$$;
revoke execute on function public.my_player_code() from public, anon;
grant execute on function public.my_player_code() to authenticated;

-- Organizer: who does this code belong to? Name and photo only.
create function public.lookup_player_code(c text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('name', name, 'photo', photo, 'mine', user_id = auth.uid())
  from public.players
  where code = upper(trim(c)) and user_id is not null and merged_into is null and auth.uid() is not null;
$$;
revoke execute on function public.lookup_player_code(text) from public, anon;
grant execute on function public.lookup_player_code(text) to authenticated;

-- Organizer: "this name on my roster is the player with this code".
create function public.link_player_code(c text, roster_pid uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  target uuid;
  tgt record;
  pl record;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into pl from public.players where code = upper(trim(c)) and user_id is not null and merged_into is null;
  if pl.id is null then raise exception 'No 10nis player has that code'; end if;
  target := public.resolve_player(roster_pid);
  if not exists (select 1 from public.rosters where owner_id = uid and player_id = target) then
    raise exception 'That name is not on your roster';
  end if;
  if target = pl.id then return jsonb_build_object('pid', pl.id, 'name', pl.name); end if;
  select * into tgt from public.players where id = target;
  if tgt.user_id is not null then raise exception 'That name is already linked to another 10nis player'; end if;
  if (tgt.kuyy_id is not null and pl.kuyy_id is not null and tgt.kuyy_id <> pl.kuyy_id)
     or (tgt.reclub_id is not null and pl.reclub_id is not null and tgt.reclub_id <> pl.reclub_id) then
    raise exception 'That name belongs to a different Kuyy or Reclub account';
  end if;
  -- Carry the name's platform ids over (unique, so free them first), then fold its history into the player.
  update public.players set kuyy_id = null, kuyy_username = null, reclub_id = null, reclub_username = null where id = target;
  update public.players set
    kuyy_id = coalesce(kuyy_id, tgt.kuyy_id), kuyy_username = coalesce(kuyy_username, tgt.kuyy_username),
    reclub_id = coalesce(reclub_id, tgt.reclub_id), reclub_username = coalesce(reclub_username, tgt.reclub_username),
    photo = coalesce(photo, tgt.photo)
  where id = pl.id;
  perform public.merge_players(target, pl.id);
  return jsonb_build_object('pid', pl.id, 'name', pl.name);
end;
$$;
revoke execute on function public.link_player_code(text, uuid) from public, anon;
grant execute on function public.link_player_code(text, uuid) to authenticated;
