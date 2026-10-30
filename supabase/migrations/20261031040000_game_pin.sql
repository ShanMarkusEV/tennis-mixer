-- Game PIN: the host gets a 6-digit PIN for a logged session; players enter it in 10nis (Join), pick their
-- name and follow the session live: which round, which court, who they play with and against, and the
-- scores. No sign-in needed to follow. Players can also turn on notifications (Web Push) for their name.
-- Anyone with the PIN can see the session's names and matches while it is active (2 days since the last
-- change); the host can turn the PIN off.

alter table public.sessions
  add column pin text unique check (pin ~ '^[1-9][0-9]{5}$'),
  add column venue text check (char_length(venue) <= 120),
  add column starts_at timestamptz;

-- Host: get (or create) the PIN for one of their sessions. PINs are unique; a PIN left on a session that
-- has been idle for two days is freed and can be handed out again.
create function public.create_pin(sid uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  p text;
begin
  select se.pin into p from public.sessions se where se.id = sid and se.user_id = auth.uid();
  if not found then raise exception 'Session not found'; end if;
  if p is not null then return p; end if;
  loop
    p := (100000 + floor(random() * 900000))::int::text;
    update public.sessions set pin = null where pin = p and updated_at < now() - interval '2 days';
    begin
      update public.sessions set pin = p where id = sid;
      return p;
    exception when unique_violation then
      -- taken by an active session: try another
    end;
  end loop;
end;
$$;
revoke execute on function public.create_pin(uuid) from public, anon;
grant execute on function public.create_pin(uuid) to authenticated;

-- Host: turn the PIN off. Followers stop seeing the session and their notifications end.
create function public.drop_pin(sid uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.sessions set pin = null where id = sid and user_id = auth.uid();
  delete from public.push_subs where session_id = sid and exists (select 1 from public.sessions where id = sid and user_id = auth.uid());
end;
$$;

-- The active session behind a PIN, or null.
create function public.pin_sid(p text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.sessions where pin = trim(p) and updated_at > now() - interval '2 days';
$$;
revoke execute on function public.pin_sid(text) from public, anon, authenticated;

-- Anyone with the PIN: the session, its roster (names, photos, who is linked) and its rounds.
create function public.pin_session(p text)
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
  host text;
begin
  select * into s from public.sessions where id = public.pin_sid(p);
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
revoke execute on function public.pin_session(text) from public;
grant execute on function public.pin_session(text) to anon, authenticated;

-- Signed-in player following by PIN: "this name is me", so the games count towards their level.
-- Same rules as a share link (claim_name), through a share token for the session.
create function public.claim_by_pin(p text, local_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  sid uuid := public.pin_sid(p);
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
revoke execute on function public.claim_by_pin(text, text) from public, anon;
grant execute on function public.claim_by_pin(text, text) to authenticated;

-- ---------- notifications ----------
-- One row per phone (push endpoint), following one name in one session. The push carries no data: the
-- phone fetches the session by PIN and words the notification itself. Only the big push services.
create table public.push_subs (
  endpoint text primary key check (char_length(endpoint) < 1000 and endpoint ~
    '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/'),
  session_id uuid not null references public.sessions on delete cascade,
  local_id text not null check (char_length(local_id) <= 40),
  created_at timestamptz not null default now()
);
create index push_subs_session_idx on public.push_subs (session_id);
alter table public.push_subs enable row level security;   -- only reachable through the functions below
revoke all on public.push_subs from anon, authenticated;

create function public.follow_push(p text, who text, ep text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  sid uuid := public.pin_sid(p);
begin
  if sid is null then raise exception 'That game PIN has expired'; end if;
  if not exists (select 1 from public.sessions se, jsonb_array_elements(se.players) e where se.id = sid and e ->> 'id' = who) then
    raise exception 'That name is not in this game';
  end if;
  if (select count(*) from public.push_subs ps where ps.session_id = sid) >= 200 then raise exception 'Too many phones follow this game'; end if;
  insert into public.push_subs as ps (endpoint, session_id, local_id) values (ep, sid, who)
    on conflict on constraint push_subs_pkey do update set session_id = excluded.session_id, local_id = excluded.local_id, created_at = now();
end;
$$;
revoke execute on function public.follow_push(text, text, text) from public;
grant execute on function public.follow_push(text, text, text) to anon, authenticated;

-- Knowing the endpoint is what proves it is your phone.
create function public.unfollow_push(ep text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.push_subs ps where ps.endpoint = ep;
$$;
revoke execute on function public.unfollow_push(text) from public;
grant execute on function public.unfollow_push(text) to anon, authenticated;

-- Host: the phones to notify for their session (called by /api/notify with the host's own login).
create function public.push_targets(sid uuid)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(ps.endpoint), '{}') from public.push_subs ps
    join public.sessions se on se.id = ps.session_id
    where ps.session_id = sid and se.user_id = auth.uid() and se.pin is not null;
$$;
revoke execute on function public.push_targets(uuid) from public, anon;
grant execute on function public.push_targets(uuid) to authenticated;

-- Host: forget phones whose push service said they are gone.
create function public.drop_push_targets(sid uuid, endpoints text[])
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.push_subs ps
    where ps.session_id = sid and ps.endpoint = any(endpoints)
      and exists (select 1 from public.sessions se where se.id = sid and se.user_id = auth.uid());
$$;
revoke execute on function public.drop_push_targets(uuid, text[]) from public, anon;
grant execute on function public.drop_push_targets(uuid, text[]) to authenticated;

revoke execute on function public.drop_pin(uuid) from public, anon;
grant execute on function public.drop_pin(uuid) to authenticated;

-- Usage counts: joining a game by PIN.
alter table public.events drop constraint events_event_check;
alter table public.events add constraint events_event_check
  check (event in ('open', 'round', 'finish', 'import', 'signin', 'install', 'error', 'join'));

create or replace function public.track(device text, event text, props jsonb default '{}', signed_in boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if device !~ '^[0-9a-f]{16}$' or event not in ('open', 'round', 'finish', 'import', 'signin', 'install', 'error', 'join') then return; end if;
  -- Ignore floods from one device (more than 500 events in a day).
  if (select count(*) from public.events e where e.device = track.device and e.created_at > now() - interval '1 day') >= 500 then return; end if;
  insert into public.events (device, event, signed_in, props)
    values (device, event, coalesce(signed_in, false),
            case when jsonb_typeof(props) = 'object' and pg_column_size(props) < 512 then props else '{}' end);
end;
$$;
