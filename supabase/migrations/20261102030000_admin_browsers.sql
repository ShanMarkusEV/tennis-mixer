-- Admin overview: which browsers open 10nis (from the daily "open" event's br prop, recorded since 0.5.1),
-- and how many of those phones did something (generated a round, joined a game or signed in) in the period.
create function public.admin_browsers(days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare since timestamptz := now() - make_interval(days => greatest(1, least(days, 365)));
begin
  perform public.require_admin();
  return coalesce((
    with opens as (
      select device, coalesce(props ->> 'br', 'Unknown (before 0.5.1)') br, created_at
      from public.events where event = 'open' and created_at >= since
    ),
    per_phone as (  -- a phone's browser is the one it last opened with
      select distinct on (device) device, br from opens order by device, created_at desc
    ),
    active as (
      select distinct device from public.events
      where event in ('round', 'join', 'signin', 'finish', 'import') and created_at >= since
    )
    select jsonb_agg(jsonb_build_object('browser', x.br, 'phones', x.phones, 'active', x.active,
             'phones_7d', x.phones_7d, 'last_seen', x.last_seen) order by x.phones desc, x.br)
    from (
      select pp.br, count(*)::int phones, count(a.device)::int active,
        count(*) filter (where exists (select 1 from opens o where o.device = pp.device and o.created_at >= now() - interval '7 days'))::int phones_7d,
        (select max(o.created_at) from opens o where o.br = pp.br) last_seen
      from per_phone pp left join active a on a.device = pp.device
      group by pp.br
    ) x), '[]'::jsonb);
end;
$$;
revoke execute on function public.admin_browsers(int) from public, anon;
grant execute on function public.admin_browsers(int) to authenticated;
