-- Read-only results of a session for someone who played in it (the organizer reads their own sessions directly).
-- Returns only what the standings need: names, photos and the rounds; never the organizer's other data.
create function public.session_results(sid uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('id', se.id, 'title', se.title, 'played_on', se.played_on,
    'players', coalesce((select jsonb_agg(jsonb_build_object('id', p ->> 'id', 'name', p ->> 'name', 'photo', p ->> 'photo'))
                         from jsonb_array_elements(coalesce(se.players, '[]'::jsonb)) p), '[]'::jsonb),
    'rounds', se.rounds)
  from public.sessions se
  where se.id = sid and auth.uid() is not null
    and (se.user_id = auth.uid() or exists (
      select 1 from public.matches m, public.players me
      where m.session_id = se.id and me.user_id = auth.uid() and me.merged_into is null
        and (me.id = any(array(select public.resolve_player(x) from unnest(m.a) x))
          or me.id = any(array(select public.resolve_player(x) from unnest(m.b) x)))));
$$;
revoke execute on function public.session_results(uuid) from public, anon;
grant execute on function public.session_results(uuid) to authenticated;
