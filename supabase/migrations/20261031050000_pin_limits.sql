-- Game PIN hardening:
-- 1. Guessing PINs: a network address that enters 30 wrong PINs within 10 minutes is paused, so walking
--    through all 900,000 PINs to find active games is impractical. Right PINs are never counted.
-- 2. Notifications: at most 5 phones per name (the newest win) instead of a 200-phone cap per game that
--    fake sign-ups could fill.

create table public.pin_misses (
  ip text not null,
  at timestamptz not null default now()
);
create index pin_misses_ip_at_idx on public.pin_misses (ip, at);
alter table public.pin_misses enable row level security;   -- internal only
revoke all on public.pin_misses from anon, authenticated;

-- The caller's address as Supabase's gateway passes it on, or null when it isn't there.
create function public.caller_ip()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(trim(split_part(coalesce(
    nullif(current_setting('request.headers', true), '')::json ->> 'cf-connecting-ip',
    nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1)), '');
$$;
revoke execute on function public.caller_ip() from public, anon, authenticated;

-- Look up a PIN for someone outside the session, counting wrong guesses per address.
create function public.pin_sid_guarded(p text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip text := public.caller_ip();
  sid uuid;
begin
  if v_ip is not null and (select count(*) from public.pin_misses m where m.ip = v_ip and m.at > now() - interval '10 minutes') >= 30 then
    raise exception 'Too many wrong PINs. Wait a few minutes and try again.';
  end if;
  sid := public.pin_sid(p);
  if sid is null and v_ip is not null then
    delete from public.pin_misses m where m.ip = v_ip and m.at < now() - interval '1 hour';
    insert into public.pin_misses (ip) values (v_ip);
  end if;
  return sid;
end;
$$;
revoke execute on function public.pin_sid_guarded(text) from public, anon, authenticated;

create or replace function public.pin_session(p text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  s record;
  res jsonb := '[]'::jsonb;
  pl jsonb;
  pid uuid;
  owner uuid;
  host text;
  sid uuid := public.pin_sid_guarded(p);   -- once: it counts wrong guesses
begin
  select * into s from public.sessions where id = sid;
  if not found then return null; end if;
  select coalesce(nullif(x.name, ''), pr.display_name) into host
    from public.profiles pr left join public.players x on x.user_id = pr.id and x.merged_into is null
    where pr.id = s.user_id;
  for pl in select * from jsonb_array_elements(coalesce(s.players, '[]'::jsonb)) loop
    pid := null; owner := null;
    if (pl ->> 'pid') ~* '^[0-9a-f-]{36}$' then
      pid := public.resolve_player((pl ->> 'pid')::uuid);
      select user_id into owner from public.players where id = pid;
    end if;
    res := res || jsonb_build_array(jsonb_build_object(
      'id', pl ->> 'id', 'name', pl ->> 'name', 'photo', pl ->> 'photo', 'active', coalesce((pl ->> 'active')::boolean, true),
      'claimable', pid is not null and owner is null, 'linked', owner is not null,
      'mine', owner is not null and owner = auth.uid()));
  end loop;
  return jsonb_build_object('pin', s.pin, 'title', s.title, 'played_on', s.played_on, 'venue', s.venue, 'starts_at', s.starts_at,
    'host', host, 'mode', s.mode, 'finished', s.finished_at is not null, 'updated_at', s.updated_at,
    'players', res, 'rounds', s.rounds);
end;
$$;

create or replace function public.follow_push(p text, who text, ep text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  sid uuid := public.pin_sid_guarded(p);
begin
  if sid is null then raise exception 'That game PIN has expired'; end if;
  if not exists (select 1 from public.sessions se, jsonb_array_elements(se.players) e where se.id = sid and e ->> 'id' = who) then
    raise exception 'That name is not in this game';
  end if;
  insert into public.push_subs as ps (endpoint, session_id, local_id) values (ep, sid, who)
    on conflict on constraint push_subs_pkey do update set session_id = excluded.session_id, local_id = excluded.local_id, created_at = now();
  -- Keep the 5 newest phones for this name.
  delete from public.push_subs ps where ps.session_id = sid and ps.local_id = who and ps.endpoint in (
    select x.endpoint from public.push_subs x where x.session_id = sid and x.local_id = who order by x.created_at desc offset 5);
end;
$$;

create or replace function public.claim_by_pin(p text, local_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  sid uuid := public.pin_sid_guarded(p);
  t text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if sid is null then raise exception 'That game PIN has expired'; end if;
  select token into t from public.session_shares where session_id = sid and expires_at > now() + interval '1 hour' limit 1;
  if t is null then
    t := left(replace(gen_random_uuid()::text, '-', ''), 16);
    insert into public.session_shares (token, session_id, owner_id)
      select t, sid, user_id from public.sessions where id = sid;
  end if;
  return public.claim_name(t, local_id);
end;
$$;
