-- Replace the signed-in user's player code. Existing links are unaffected (they point at the player record,
-- not the code); the old code simply stops working for new links.
create function public.new_player_code()
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update public.players set code = null where user_id = auth.uid() and merged_into is null;
  return public.my_player_code();
end;
$$;
revoke execute on function public.new_player_code() from public, anon;
grant execute on function public.new_player_code() to authenticated;
