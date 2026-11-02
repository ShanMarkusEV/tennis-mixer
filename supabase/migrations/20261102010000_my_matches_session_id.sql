-- My matches also returns the session id, so the app can show them in one list with the organizer's own session log.
create or replace function public.my_matches(max_sessions int default 30)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with me as (
    select id from public.players where user_id = auth.uid() and merged_into is null
  ),
  mine as (
    select m.*, se.user_id host_id, se.mode, se.created_at, se.title,
           array(select public.resolve_player(x) from unnest(m.a) x) ra,
           array(select public.resolve_player(x) from unnest(m.b) x) rb
    from public.matches m join public.sessions se on se.id = m.session_id
  ),
  rows as (
    select mi.*, me.id me_id, (me.id = any(mi.ra)) on_a, mr.before, mr.after
    from mine mi cross join me
    left join public.match_ratings mr on mr.match_id = mi.id and mr.player_id = me.id
    where me.id = any(mi.ra) or me.id = any(mi.rb)
  ),
  named as (
    select r.*,
      array(select coalesce(pl.name, '?') from unnest(case when r.on_a then r.ra else r.rb end) with ordinality t(x, o)
            left join public.players pl on pl.id = t.x where t.x <> r.me_id order by o) partners,
      array(select coalesce(pl.name, '?') from unnest(case when r.on_a then r.rb else r.ra end) with ordinality t(x, o)
            left join public.players pl on pl.id = t.x order by o) opponents,
      case when r.on_a then r.sa else r.sb end mine_score,
      case when r.on_a then r.sb else r.sa end their_score
    from rows r
  ),
  sessions as (
    select n.session_id, n.played_on, n.created_at, n.host_id, n.mode, n.title,
      jsonb_agg(jsonb_build_object(
        'partners', to_jsonb(n.partners), 'opponents', to_jsonb(n.opponents),
        'mine', n.mine_score, 'theirs', n.their_score,
        'before', round(least(10, greatest(1, 1 + (n.before - 800) / 100)), 1),
        'after', round(least(10, greatest(1, 1 + (n.after - 800) / 100)), 1)) order by n.seq) matches,
      (array_agg(n.before order by n.seq))[1] first_before,
      (array_agg(n.after order by n.seq desc))[1] last_after
    from named n
    group by n.session_id, n.played_on, n.created_at, n.host_id, n.mode, n.title
    order by n.played_on desc, n.created_at desc
    limit greatest(1, least(max_sessions, 100))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'session_id', s.session_id, 'played_on', s.played_on, 'mode', s.mode, 'title', s.title,
      'host', case when s.host_id = auth.uid() then null
                   else coalesce((select name from public.players where user_id = s.host_id and merged_into is null),
                                 (select i.name from public.account_identity(s.host_id) i)) end,
      'before', round(least(10, greatest(1, 1 + (s.first_before - 800) / 100)), 1),
      'after', round(least(10, greatest(1, 1 + (s.last_after - 800) / 100)), 1),
      'matches', s.matches) order by s.played_on desc, s.created_at desc), '[]'::jsonb)
  from sessions s;
$$;
