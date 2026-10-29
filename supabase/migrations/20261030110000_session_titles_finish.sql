-- Sessions get a name (title: a fun generated one, or the imported Kuyy/Reclub activity name) and can be
-- finished. A finished session stays in the organizer's log and its scores can still be edited.
alter table public.sessions add column finished_at timestamptz;

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
      'played_on', s.played_on, 'mode', s.mode, 'title', s.title,
      'host', case when s.host_id = auth.uid() then null
                   else coalesce((select name from public.players where user_id = s.host_id and merged_into is null),
                                 (select i.name from public.account_identity(s.host_id) i)) end,
      'before', round(least(10, greatest(1, 1 + (s.first_before - 800) / 100)), 1),
      'after', round(least(10, greatest(1, 1 + (s.last_after - 800) / 100)), 1),
      'matches', s.matches) order by s.played_on desc, s.created_at desc), '[]'::jsonb)
  from sessions s;
$$;

create or replace function public.share_roster(t text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  s record;
  res jsonb := '[]'::jsonb;
  pl jsonb;
  pid uuid;
  owner uuid;
begin
  select ss.session_id, se.played_on, se.players, se.title into s
    from public.session_shares ss join public.sessions se on se.id = ss.session_id
    where ss.token = t and ss.expires_at > now();
  if not found then return null; end if;
  for pl in select * from jsonb_array_elements(coalesce(s.players, '[]'::jsonb)) loop
    pid := null; owner := null;
    if (pl ->> 'pid') ~* '^[0-9a-f-]{36}$' then
      pid := public.resolve_player((pl ->> 'pid')::uuid);
      select user_id into owner from public.players where id = pid;
    end if;
    res := res || jsonb_build_array(jsonb_build_object(
      'local', pl ->> 'id', 'name', pl ->> 'name', 'photo', pl ->> 'photo',
      'claimable', pid is not null, 'claimed', owner is not null,
      'mine', owner is not null and owner = auth.uid()));
  end loop;
  return jsonb_build_object('played_on', s.played_on, 'title', s.title, 'players', res);
end;
$$;
