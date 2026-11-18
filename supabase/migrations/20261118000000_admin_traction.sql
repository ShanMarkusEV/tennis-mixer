-- Dashboard v2 (/ad4min): one read-only function for the traction view. Weekly active players, weekly cohorts,
-- use per feature, Gear numbers, where new phones come from, and account health. Admin only.
-- Safe to run: it only creates (or replaces) this one function. No table is created, changed or emptied.
--
-- "Active" = an account that did something: finished a diary session, saved a coaching note, added or changed a
-- racket, or hosted a mabar with at least one round. Counted per account, so link-preview bots don't count.
-- Weeks run Monday to Sunday, Jakarta time.

create or replace function public.admin_traction()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  jkt date := (now() at time zone 'Asia/Jakarta')::date;
  wk date := date_trunc('week', (now() at time zone 'Asia/Jakarta'))::date;   -- this week's Monday
begin
  perform public.require_admin();
  return (
    with act as (
      select user_id, ended_at as at, 'diary' as f from public.plays where ended_at is not null
      union all select user_id, created_at, 'coaching' from public.coach_sessions
      union all select user_id, created_at, 'gear' from public.rackets
      union all select user_id, updated_at, 'gear' from public.rackets
      union all select user_id, created_at, 'mabar' from public.sessions where jsonb_array_length(coalesce(rounds, '[]')) > 0
      union all select user_id, finished_at, 'mabar' from public.sessions where finished_at is not null and jsonb_array_length(coalesce(rounds, '[]')) > 0),
    aw as (select user_id, f, at, date_trunc('week', (at at time zone 'Asia/Jakarta'))::date as w from act),
    firsts as (select user_id, min(w) as w0 from aw group by user_id),
    weeks as (select generate_series(wk - 49, wk, interval '7 days')::date as w),
    ev as (select device, event, props, created_at from public.events where created_at > now() - interval '30 days'),
    -- Phones that did something real, for "where do new phones come from".
    doers as (select distinct device from ev where event in ('play_start', 'les_save', 'gear_add', 'round', 'join', 'finish')),
    src as (select device, props ->> 'src' as src, props ->> 'topic' as topic from ev where event = 'open' and props ? 'src'),
    -- String wear the way the app shows it, with 4 hours a week (the app's default; the real value is per phone).
    rk as (select r.*, greatest(0, jkt - r.strung_on) as days,
        case when r.cross_type is not null and r.cross_type <> r.string_type and 'poly' in (r.string_type, r.cross_type) then 'hybrid'
             else coalesce(r.string_type, 'poly') end as life_type
      from public.rackets r),
    rw as (select rk.*, greatest(rk.days / 7.0 * 4 / l.h, rk.days / 7.0 / l.w) as pct
      from rk join (values ('poly', 20, 6), ('hybrid', 25, 8), ('multi', 30, 10), ('syn', 30, 10), ('gut', 40, 12)) as l(t, h, w)
        on l.t = rk.life_type where rk.strung_on is not null)
    select jsonb_build_object(
      'week', wk,
      'wau', (select count(distinct user_id) from act where at > now() - interval '7 days'),
      'wau_prev', (select count(distinct user_id) from act where at > now() - interval '14 days' and at <= now() - interval '7 days'),
      'weekly', (select jsonb_agg(jsonb_build_object('w', weeks.w,
          'active', (select count(distinct user_id) from aw where aw.w = weeks.w),
          'new', (select count(*) from firsts where firsts.w0 = weeks.w)) order by weeks.w) from weeks),
      'cohorts', (select jsonb_agg(jsonb_build_object('w', weeks.w,
          'n', (select count(*) from firsts where w0 = weeks.w),
          'w1', case when weeks.w + 7 <= wk then (select count(*) from firsts c where c.w0 = weeks.w
                  and exists (select 1 from aw where aw.user_id = c.user_id and aw.w = weeks.w + 7)) end,
          'w2', case when weeks.w + 14 <= wk then (select count(*) from firsts c where c.w0 = weeks.w
                  and exists (select 1 from aw where aw.user_id = c.user_id and aw.w = weeks.w + 14)) end,
          'w4', case when weeks.w + 28 <= wk then (select count(*) from firsts c where c.w0 = weeks.w
                  and exists (select 1 from aw where aw.user_id = c.user_id and aw.w = weeks.w + 28)) end) order by weeks.w desc)
        from weeks),
      'features', (select jsonb_agg(jsonb_build_object('f', x.f,
          'd7', (select count(distinct user_id) from act where act.f = x.f and at > now() - interval '7 days'),
          'd30', (select count(distinct user_id) from act where act.f = x.f and at > now() - interval '30 days'),
          'ever', (select count(distinct user_id) from act where act.f = x.f)) order by x.o)
        from (values ('diary', 1), ('coaching', 2), ('gear', 3), ('mabar', 4)) as x(f, o)),
      'multi_30d', (select count(*) from (select user_id from act where at > now() - interval '30 days'
        group by user_id having count(distinct f) >= 2) m),
      'active_30d', (select count(distinct user_id) from act where at > now() - interval '30 days'),
      'gear', jsonb_build_object(
        'rackets', (select count(*) from public.rackets),
        'players', (select count(distinct user_id) from public.rackets),
        'restrings', (select coalesce(sum(jsonb_array_length(restrings)), 0) from public.rackets),
        'restrings_30d', (select count(*) from ev where event = 'gear_restring'),
        'dated', (select count(*) from public.rackets where strung_on is not null),
        'catalog', (select count(*) from public.rackets where model_id is not null),
        'red', (select count(*) from rw where pct >= 1),
        'amber', (select count(*) from rw where pct >= .8 and pct < 1),
        'types', (select coalesce(jsonb_agg(jsonb_build_object('t', t, 'n', n) order by n desc), '[]')
          from (select coalesce(string_type, 'none') as t, count(*) as n from public.rackets group by 1) z)),
      'mabar', jsonb_build_object(
        'finished_manual_30d', (select count(*) from ev where event = 'finish' and coalesce(props ->> 'auto', 'false') <> 'true'),
        'finished_auto_30d', (select count(*) from ev where event = 'finish' and props ->> 'auto' = 'true'),
        'hosts_30d', (select count(distinct user_id) from act where f = 'mabar' and at > now() - interval '30 days')),
      'sources', (select coalesce(jsonb_agg(jsonb_build_object('src', s, 'phones', n, 'doers', d) order by n desc), '[]')
        from (select src as s, count(distinct device) as n, count(distinct device) filter (where device in (select device from doers)) as d
              from src group by src) z),
      'topics', (select coalesce(jsonb_agg(jsonb_build_object('topic', t, 'phones', n) order by n desc), '[]')
        from (select topic as t, count(distinct device) as n from src where src = 'latihan' and topic is not null group by topic) z),
      'accounts', jsonb_build_object(
        'guests_30d', (select count(distinct device) from ev where event = 'guest'),
        'linked_30d', (select count(distinct device) from ev where event = 'linked'),
        'merged_30d', (select count(distinct device) from ev where event = 'merged'),
        'signins_7d', (select count(*) from ev where event = 'signin' and created_at > now() - interval '7 days'),
        'signin_phones_7d', (select count(distinct device) from ev where event = 'signin' and created_at > now() - interval '7 days'),
        'relogin_phones_7d', (select count(*) from (select device from ev where event = 'signin' and created_at > now() - interval '7 days'
          group by device having count(*) > 2) z),
        'relogin_phones_30d', (select count(*) from (select device from ev where event = 'signin' group by device having count(*) > 2) z))));
end;
$$;
revoke execute on function public.admin_traction() from public, anon;
grant execute on function public.admin_traction() to authenticated;
