-- Anonymous usage counts, including people who never sign in.
-- Each phone has a random id made on the device (not tied to a name, account or IP). Events are written
-- through track() only; nothing here is readable through the app's API. The owner reads the views
-- usage_daily / usage_weekly in the Supabase dashboard.

create table public.events (
  id bigserial primary key,
  device text not null check (device ~ '^[0-9a-f]{16}$'),
  event text not null check (event in ('open', 'round', 'finish', 'import', 'signin')),
  signed_in boolean not null default false,
  props jsonb not null default '{}' check (jsonb_typeof(props) = 'object' and pg_column_size(props) < 512),
  created_at timestamptz not null default now()
);
create index events_device_time_idx on public.events (device, created_at);
create index events_time_idx on public.events (created_at);
alter table public.events enable row level security;   -- no policies: write through track(), read in the dashboard
revoke all on public.events from anon, authenticated;

create function public.track(device text, event text, props jsonb default '{}', signed_in boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if device !~ '^[0-9a-f]{16}$' or event not in ('open', 'round', 'finish', 'import', 'signin') then return; end if;
  -- Ignore floods from one device (more than 500 events in a day).
  if (select count(*) from public.events e where e.device = track.device and e.created_at > now() - interval '1 day') >= 500 then return; end if;
  insert into public.events (device, event, signed_in, props)
    values (device, event, coalesce(signed_in, false),
            case when jsonb_typeof(props) = 'object' and pg_column_size(props) < 512 then props else '{}' end);
end;
$$;
revoke execute on function public.track(text, text, jsonb, boolean) from public;
grant execute on function public.track(text, text, jsonb, boolean) to anon, authenticated;

-- Dashboard views (owner only). Days are Jakarta time.
create view public.usage_daily with (security_invoker = true) as
  select (created_at at time zone 'Asia/Jakarta')::date as day,
    count(distinct device) as active_phones,
    count(distinct device) filter (where signed_in) as signed_in_phones,
    count(distinct device) filter (where event = 'round') as phones_that_played,
    count(*) filter (where event = 'round') as rounds,
    count(*) filter (where event = 'finish') as sessions_finished,
    count(*) filter (where event = 'import' and props ->> 'source' = 'Kuyy') as kuyy_imports,
    count(*) filter (where event = 'import' and props ->> 'source' = 'Reclub') as reclub_imports,
    count(*) filter (where event = 'signin') as sign_ins
  from public.events
  group by 1
  order by 1 desc;

create view public.usage_weekly with (security_invoker = true) as
  select date_trunc('week', created_at at time zone 'Asia/Jakarta')::date as week_starting,
    count(distinct device) as active_phones,
    count(distinct device) filter (where signed_in) as signed_in_phones,
    count(distinct device) filter (where event = 'round') as phones_that_played,
    count(*) filter (where event = 'round') as rounds,
    count(*) filter (where event = 'finish') as sessions_finished,
    count(*) filter (where event = 'import') as imports
  from public.events
  group by 1
  order by 1 desc;

revoke all on public.usage_daily, public.usage_weekly from anon, authenticated;
