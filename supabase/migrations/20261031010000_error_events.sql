-- Diagnostics: the app reports failed server calls as an anonymous "error" event (where it failed and the
-- error message), so problems on people's phones can be found without asking them to reproduce them.
alter table public.events drop constraint events_event_check;
alter table public.events add constraint events_event_check check (event in ('open', 'round', 'finish', 'import', 'signin', 'install', 'error'));

create or replace function public.track(device text, event text, props jsonb default '{}', signed_in boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if device !~ '^[0-9a-f]{16}$' or event not in ('open', 'round', 'finish', 'import', 'signin', 'install', 'error') then return; end if;
  -- Ignore floods from one device (more than 500 events in a day).
  if (select count(*) from public.events e where e.device = track.device and e.created_at > now() - interval '1 day') >= 500 then return; end if;
  insert into public.events (device, event, signed_in, props)
    values (device, event, coalesce(signed_in, false),
            case when jsonb_typeof(props) = 'object' and pg_column_size(props) < 512 then props else '{}' end);
end;
$$;

-- Recent errors, newest first (owner only, in the dashboard).
create view public.usage_errors with (security_invoker = true) as
  select created_at at time zone 'Asia/Jakarta' as at_jakarta, props ->> 'where' as where_, props ->> 'msg' as message,
    props ->> 'v' as version, signed_in, left(device, 6) as phone
  from public.events
  where event = 'error'
  order by created_at desc;
revoke all on public.usage_errors from anon, authenticated;
