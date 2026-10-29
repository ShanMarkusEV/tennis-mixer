-- Players choose the name shown on their record (and so on organizers' rosters, on their next sync).
-- null or empty goes back to the Google account name.
create function public.set_my_name(new_name text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  me uuid;
  nm text := nullif(regexp_replace(trim(coalesce(new_name, '')), '\s+', ' ', 'g'), '');
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if nm is not null and char_length(nm) > 40 then raise exception 'Keep your name under 40 characters'; end if;
  select id into me from public.players where user_id = uid and merged_into is null;
  if me is null then
    perform public.my_player_code();   -- creates the record
    select id into me from public.players where user_id = uid and merged_into is null;
  end if;
  if nm is null then
    update public.profiles set display_name = null where id = uid;
    select i.name into nm from public.account_identity(uid) i;
  else
    update public.profiles set display_name = nm where id = uid;
  end if;
  update public.players set name = nm where id = me;
  return nm;
end;
$$;
revoke execute on function public.set_my_name(text) from public, anon;
grant execute on function public.set_my_name(text) to authenticated;
