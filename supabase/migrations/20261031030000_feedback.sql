-- "Report a problem": anyone (signed in or not) can send a short message from the app, with optional contact
-- details and context the app attaches (version, screen, recent errors). Read in the dashboard (feedback_inbox).
create table public.feedback (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  message text not null check (char_length(message) between 3 and 2000),
  contact text check (char_length(contact) <= 200),
  user_id uuid references auth.users on delete set null,
  device text check (device ~ '^[0-9a-f]{16}$'),
  context jsonb not null default '{}' check (jsonb_typeof(context) = 'object' and pg_column_size(context) < 4096),
  resolved boolean not null default false
);
create index feedback_device_time_idx on public.feedback (device, created_at);
alter table public.feedback enable row level security;   -- written through submit_feedback(), read in the dashboard
revoke all on public.feedback from anon, authenticated;

create function public.submit_feedback(message text, contact text default null, device text default null, context jsonb default '{}')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare msg text := trim(coalesce(message, ''));
begin
  if char_length(msg) < 3 then raise exception 'Please describe the problem'; end if;
  if device is not null and device !~ '^[0-9a-f]{16}$' then device := null; end if;
  if device is not null and (select count(*) from public.feedback f where f.device = submit_feedback.device
                             and f.created_at > now() - interval '1 day') >= 10 then
    raise exception 'Thanks, we already have your reports from today';
  end if;
  insert into public.feedback (message, contact, user_id, device, context)
    values (left(msg, 2000), left(nullif(trim(coalesce(contact, '')), ''), 200), auth.uid(), device,
            case when jsonb_typeof(context) = 'object' and pg_column_size(context) < 4096 then context else '{}' end);
end;
$$;
revoke execute on function public.submit_feedback(text, text, text, jsonb) from public;
grant execute on function public.submit_feedback(text, text, text, jsonb) to anon, authenticated;

create view public.feedback_inbox with (security_invoker = true) as
  select f.id, f.created_at at time zone 'Asia/Jakarta' as at_jakarta, f.resolved, f.message, f.contact,
    coalesce(p.name, u.raw_user_meta_data ->> 'full_name') as account_name, u.email as account_email,
    f.context ->> 'v' as version, f.context ->> 'tab' as screen, f.context -> 'errors' as recent_errors,
    f.context ->> 'ua' as browser, left(f.device, 6) as phone
  from public.feedback f
  left join auth.users u on u.id = f.user_id
  left join public.players p on p.user_id = f.user_id and p.merged_into is null
  order by f.created_at desc;
revoke all on public.feedback_inbox from anon, authenticated;
