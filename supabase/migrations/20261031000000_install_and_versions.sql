-- Usage counts learn two more things: installs to the home screen, and which app version each phone runs
-- (props.v on every event; props.standalone on "open" when the installed app is used).
alter table public.events drop constraint events_event_check;
alter table public.events add constraint events_event_check check (event in ('open', 'round', 'finish', 'import', 'signin', 'install'));

create or replace function public.track(device text, event text, props jsonb default '{}', signed_in boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if device !~ '^[0-9a-f]{16}$' or event not in ('open', 'round', 'finish', 'import', 'signin', 'install') then return; end if;
  -- Ignore floods from one device (more than 500 events in a day).
  if (select count(*) from public.events e where e.device = track.device and e.created_at > now() - interval '1 day') >= 500 then return; end if;
  insert into public.events (device, event, signed_in, props)
    values (device, event, coalesce(signed_in, false),
            case when jsonb_typeof(props) = 'object' and pg_column_size(props) < 512 then props else '{}' end);
end;
$$;

create or replace view public.usage_daily with (security_invoker = true) as
  select (created_at at time zone 'Asia/Jakarta')::date as day,
    count(distinct device) as active_phones,
    count(distinct device) filter (where signed_in) as signed_in_phones,
    count(distinct device) filter (where event = 'round') as phones_that_played,
    count(*) filter (where event = 'round') as rounds,
    count(*) filter (where event = 'finish') as sessions_finished,
    count(*) filter (where event = 'import' and props ->> 'source' = 'Kuyy') as kuyy_imports,
    count(*) filter (where event = 'import' and props ->> 'source' = 'Reclub') as reclub_imports,
    count(*) filter (where event = 'signin') as sign_ins,
    count(distinct device) filter (where event = 'open' and props ->> 'standalone' = 'true') as phones_using_installed_app,
    count(*) filter (where event = 'install') as installs
  from public.events
  group by 1
  order by 1 desc;

-- Which versions are out there: phones seen on each version, and when it was last used.
create view public.usage_versions with (security_invoker = true) as
  select coalesce(props ->> 'v', 'before versioning') as version,
    count(distinct device) as phones,
    count(distinct device) filter (where created_at > now() - interval '7 days') as phones_last_7_days,
    min(created_at) as first_seen,
    max(created_at) as last_seen
  from public.events
  group by 1
  order by max(created_at) desc;

revoke all on public.usage_daily, public.usage_versions from anon, authenticated;
