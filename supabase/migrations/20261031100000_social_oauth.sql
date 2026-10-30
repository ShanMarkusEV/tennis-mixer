-- "Connect Threads" in /ad4min: the admin signs in to Threads and approves the app; the server swaps the
-- returned code for a 60-day token and stores it. A one-time state value, created for the signed-in admin and
-- used within 15 minutes, ties the Threads callback to that admin, so nobody else can attach their account.

create table public.social_oauth_states (
  state_sha256 text primary key,
  admin_id uuid not null,
  created_at timestamptz not null default now()
);
alter table public.social_oauth_states enable row level security;
revoke all on public.social_oauth_states from anon, authenticated;

create function public.admin_social_oauth_start()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare st text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  perform public.require_admin();
  delete from public.social_oauth_states where created_at < now() - interval '15 minutes';
  insert into public.social_oauth_states (state_sha256, admin_id) values (encode(extensions.digest(st, 'sha256'), 'hex'), auth.uid());
  perform public.admin_note('connect threads', null);
  return st;
end;
$$;
revoke execute on function public.admin_social_oauth_start() from public, anon;
grant execute on function public.admin_social_oauth_start() to authenticated;

-- For the callback (proved by the cron secret): use up a state; true only once, within 15 minutes.
create function public.social_cron_oauth_take(secret text, st text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.social_require(secret);
  delete from public.social_oauth_states
    where state_sha256 = encode(extensions.digest(coalesce(st, ''), 'sha256'), 'hex') and created_at > now() - interval '15 minutes';
  return found;
end;
$$;
revoke execute on function public.social_cron_oauth_take(text, text) from public;
grant execute on function public.social_cron_oauth_take(text, text) to anon, authenticated;
