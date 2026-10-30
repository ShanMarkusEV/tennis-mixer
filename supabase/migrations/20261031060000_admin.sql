-- Admin console (10nis.win/ad4min) for the app's creator: usage numbers and managing users, sessions,
-- players, feedback and usage events.
-- Who can use it is decided here, not by the page: a caller must be on public.admins AND have signed in
-- with a second factor (an authenticator-app code) in this login session (JWT aal = aal2). Every admin
-- function checks that first; every change is written to admin_log. Nothing here is reachable by anon.

create table public.admins (
  user_id uuid primary key references auth.users on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.admins enable row level security;   -- no policies: never readable or writable through the API
revoke all on public.admins from anon, authenticated;
insert into public.admins (user_id) select id from auth.users where email = 'shanmarkusdiablo@gmail.com';

create table public.admin_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  admin_id uuid,
  action text not null,
  target text,
  detail jsonb not null default '{}'
);
alter table public.admin_log enable row level security;
revoke all on public.admin_log from anon, authenticated;

create function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.admins a where a.user_id = auth.uid())
     and coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- For the admin page: is this login on the list, and has it passed the second factor yet?
create function public.admin_check()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('listed', exists (select 1 from public.admins a where a.user_id = auth.uid()),
                            'aal', coalesce(auth.jwt() ->> 'aal', 'aal1'));
$$;
revoke execute on function public.admin_check() from public, anon;
grant execute on function public.admin_check() to authenticated;

create function public.require_admin()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'Not allowed' using errcode = '42501'; end if;
end;
$$;
revoke execute on function public.require_admin() from public, anon, authenticated;

create function public.admin_note(action text, target text, detail jsonb default '{}')
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.admin_log (admin_id, action, target, detail) values (auth.uid(), action, target, coalesce(detail, '{}'));
$$;
revoke execute on function public.admin_note(text, text, jsonb) from public, anon, authenticated;

-- Admins may delete any profile photo (used when deleting a user).
create policy "Admins delete avatars" on storage.objects
  for delete to authenticated using (bucket_id = 'avatars' and public.is_admin());

-- ---------- numbers ----------
create function public.admin_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  jkt date := (now() at time zone 'Asia/Jakarta')::date;
begin
  perform public.require_admin();
  return jsonb_build_object(
    'accounts', (select count(*) from auth.users),
    'accounts_7d', (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'accounts_30d', (select count(*) from auth.users where created_at > now() - interval '30 days'),
    'signed_in_7d', (select count(*) from auth.users where last_sign_in_at > now() - interval '7 days'),
    'phones', (select count(distinct device) from public.events),
    'phones_today', (select count(distinct device) from public.events where (created_at at time zone 'Asia/Jakarta')::date = jkt),
    'phones_7d', (select count(distinct device) from public.events where created_at > now() - interval '7 days'),
    'phones_30d', (select count(distinct device) from public.events where created_at > now() - interval '30 days'),
    'installs', (select count(distinct device) from public.events where event = 'install'),
    'joins_7d', (select count(*) from public.events where event = 'join' and created_at > now() - interval '7 days'),
    'sessions', (select count(*) from public.sessions),
    'sessions_7d', (select count(*) from public.sessions where created_at > now() - interval '7 days'),
    'sessions_finished', (select count(*) from public.sessions where finished_at is not null),
    'rounds', (select coalesce(sum(jsonb_array_length(rounds)), 0) from public.sessions),
    'matches', (select count(*) from public.matches),
    'matches_7d', (select count(*) from public.matches where played_on > jkt - 7),
    'players', (select count(*) from public.players where merged_into is null),
    'players_linked', (select count(*) from public.players where merged_into is null and user_id is not null),
    'players_rated', (select count(*) from public.ratings where matches > 0),
    'pins_active', (select count(*) from public.sessions where pin is not null and updated_at > now() - interval '2 days'),
    'followers', (select count(*) from public.push_subs),
    'feedback_open', (select count(*) from public.feedback where not resolved),
    'errors_7d', (select count(*) from public.events where event = 'error' and created_at > now() - interval '7 days'),
    'daily', (select jsonb_agg(jsonb_build_object('day', d.day,
        'phones', (select count(distinct device) from public.events e where (e.created_at at time zone 'Asia/Jakarta')::date = d.day),
        'signups', (select count(*) from auth.users u where (u.created_at at time zone 'Asia/Jakarta')::date = d.day),
        'sessions', (select count(*) from public.sessions s where (s.created_at at time zone 'Asia/Jakarta')::date = d.day),
        'matches', (select count(*) from public.matches m where m.played_on = d.day)) order by d.day)
      from (select generate_series(jkt - 29, jkt, interval '1 day')::date as day) d),
    'versions', (select coalesce(jsonb_agg(to_jsonb(v)), '[]') from public.usage_versions v),
    'formats', (select jsonb_build_object(
        'social', count(*) filter (where mode = 'americano'), 'competitive', count(*) filter (where mode = 'mexicano'))
      from public.sessions));
end;
$$;
revoke execute on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated;

-- ---------- lists ----------
-- kind: users | sessions | players | feedback | errors | log. q searches names, emails and titles.
create function public.admin_list(kind text, q text default '', lim int default 50, off int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  pat text := '%' || coalesce(trim(q), '') || '%';
  n int := greatest(1, least(coalesce(lim, 50), 200));
  o int := greatest(0, coalesce(off, 0));
  res jsonb;
begin
  perform public.require_admin();
  if kind = 'users' then
    select coalesce(jsonb_agg(r), '[]') into res from (
      select u.id, u.email, coalesce(pl.name, pr.display_name, u.raw_user_meta_data ->> 'full_name') as name,
        u.created_at, u.last_sign_in_at, pl.id as player_id, pl.code, pl.self_level, pl.photo,
        rt.score, rt.matches, (select count(*) from public.sessions s where s.user_id = u.id) as sessions,
        exists (select 1 from public.admins a where a.user_id = u.id) as admin
      from auth.users u
      left join public.profiles pr on pr.id = u.id
      left join public.players pl on pl.user_id = u.id and pl.merged_into is null
      left join public.ratings rt on rt.player_id = pl.id
      where coalesce(u.email, '') ilike pat or coalesce(pl.name, pr.display_name, u.raw_user_meta_data ->> 'full_name', '') ilike pat
      order by u.created_at desc limit n offset o) r;
  elsif kind = 'sessions' then
    select coalesce(jsonb_agg(r), '[]') into res from (
      select s.id, s.title, s.played_on, s.created_at, s.updated_at, s.finished_at, s.pin, s.venue, s.mode,
        jsonb_array_length(s.rounds) as rounds, jsonb_array_length(s.players) as players,
        (select count(*) from public.matches m where m.session_id = s.id) as matches,
        u.email as host_email, coalesce(pl.name, u.raw_user_meta_data ->> 'full_name') as host
      from public.sessions s
      join auth.users u on u.id = s.user_id
      left join public.players pl on pl.user_id = s.user_id and pl.merged_into is null
      where coalesce(s.title, '') ilike pat or u.email ilike pat or coalesce(pl.name, '') ilike pat or coalesce(s.pin, '') ilike pat
      order by s.created_at desc limit n offset o) r;
  elsif kind = 'players' then
    select coalesce(jsonb_agg(r), '[]') into res from (
      select p.id, p.name, p.photo, p.code, p.self_level, p.created_at, p.user_id, u.email,
        coalesce(op.name, ou.raw_user_meta_data ->> 'full_name') as owner, rt.score, rt.matches,
        case when p.kuyy_id is not null then 'Kuyy' when p.reclub_id is not null then 'Reclub' end as source
      from public.players p
      left join auth.users u on u.id = p.user_id
      left join auth.users ou on ou.id = p.owner_id
      left join public.players op on op.user_id = p.owner_id and op.merged_into is null
      left join public.ratings rt on rt.player_id = p.id
      where p.merged_into is null and (p.name ilike pat or coalesce(u.email, '') ilike pat or coalesce(p.code, '') ilike pat)
      order by p.created_at desc limit n offset o) r;
  elsif kind = 'feedback' then
    select coalesce(jsonb_agg(r), '[]') into res from (
      select f.* from public.feedback_inbox f
      where f.message ilike pat or coalesce(f.contact, '') ilike pat or coalesce(f.account_name, '') ilike pat
      limit n offset o) r;
  elsif kind = 'errors' then
    select coalesce(jsonb_agg(r), '[]') into res from (
      select e.* from public.usage_errors e where coalesce(e.message, '') ilike pat or coalesce(e.where_, '') ilike pat
      limit n offset o) r;
  elsif kind = 'log' then
    select coalesce(jsonb_agg(r), '[]') into res from (
      select l.at, l.action, l.target, l.detail, u.email as admin
      from public.admin_log l left join auth.users u on u.id = l.admin_id
      order by l.at desc limit n offset o) r;
  else
    raise exception 'Unknown list %', kind;
  end if;
  return res;
end;
$$;
revoke execute on function public.admin_list(text, text, int, int) from public, anon;
grant execute on function public.admin_list(text, text, int, int) to authenticated;

-- One session in full (roster and rounds), for viewing.
create function public.admin_session(sid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();
  return (select to_jsonb(s) from public.sessions s where s.id = sid);
end;
$$;
revoke execute on function public.admin_session(uuid) from public, anon;
grant execute on function public.admin_session(uuid) to authenticated;

-- ---------- changes ----------
create function public.admin_update_user(uid uuid, new_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare nm text := left(nullif(trim(coalesce(new_name, '')), ''), 40);
begin
  perform public.require_admin();
  if nm is null then raise exception 'Name can''t be empty'; end if;
  update public.profiles set display_name = nm where id = uid;
  update public.players set name = nm where user_id = uid and merged_into is null;
  perform public.admin_note('rename user', uid::text, jsonb_build_object('name', nm));
end;
$$;

create function public.admin_delete_user(uid uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare em text;
begin
  perform public.require_admin();
  if uid = auth.uid() then raise exception 'You can''t delete your own admin account here'; end if;
  select email into em from auth.users where id = uid;
  if em is null then raise exception 'User not found'; end if;
  delete from auth.users where id = uid;
  perform public.recompute_ratings();
  perform public.admin_note('delete user', uid::text, jsonb_build_object('email', em));
end;
$$;

create function public.admin_update_session(sid uuid, new_title text, new_venue text, finished boolean, pin_off boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();
  update public.sessions set
    title = left(nullif(trim(coalesce(new_title, '')), ''), 120),
    venue = left(nullif(trim(coalesce(new_venue, '')), ''), 120),
    finished_at = case when finished then coalesce(finished_at, now()) end,
    pin = case when pin_off then null else pin end
  where id = sid;
  if not found then raise exception 'Session not found'; end if;
  if pin_off then delete from public.push_subs where session_id = sid; end if;
  perform public.admin_note('edit session', sid::text,
    jsonb_build_object('title', new_title, 'venue', new_venue, 'finished', finished, 'pin_off', pin_off));
end;
$$;

create function public.admin_delete_session(sid uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare t text;
begin
  perform public.require_admin();
  select coalesce(title, played_on::text) into t from public.sessions where id = sid;
  if t is null then raise exception 'Session not found'; end if;
  delete from public.sessions where id = sid;   -- matches, shares and followers go with it; the trigger re-rates
  perform public.admin_note('delete session', sid::text, jsonb_build_object('title', t));
end;
$$;

create function public.admin_update_player(pid uuid, new_name text, new_level int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  nm text := left(nullif(trim(coalesce(new_name, '')), ''), 80);
  old record;
begin
  perform public.require_admin();
  if nm is null then raise exception 'Name can''t be empty'; end if;
  if new_level is not null and new_level not between 1 and 10 then raise exception 'Level must be 1 to 10'; end if;
  select * into old from public.players where id = pid and merged_into is null;
  if old.id is null then raise exception 'Player not found'; end if;
  update public.players set name = nm, self_level = new_level where id = pid;
  if old.user_id is not null then update public.profiles set display_name = nm where id = old.user_id; end if;
  if old.self_level is distinct from new_level then perform public.recompute_ratings(); end if;
  perform public.admin_note('edit player', pid::text, jsonb_build_object('name', nm, 'self_level', new_level));
end;
$$;

-- Only names nobody has played with and no account owns (e.g. typos left on a roster).
create function public.admin_delete_player(pid uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare p record;
begin
  perform public.require_admin();
  select * into p from public.players where id = pid and merged_into is null;
  if p.id is null then raise exception 'Player not found'; end if;
  if p.user_id is not null then raise exception 'This player has an account: delete the user instead'; end if;
  if exists (select 1 from public.matches m where pid = any(m.a) or pid = any(m.b)) then
    raise exception 'This player has games: rename them instead';
  end if;
  delete from public.players where id = pid;
  perform public.admin_note('delete player', pid::text, jsonb_build_object('name', p.name));
end;
$$;

create function public.admin_feedback(fid bigint, done boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();
  update public.feedback set resolved = done where id = fid;
  perform public.admin_note(case when done then 'resolve feedback' else 'reopen feedback' end, fid::text);
end;
$$;

create function public.admin_delete_feedback(fid bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();
  delete from public.feedback where id = fid;
  perform public.admin_note('delete feedback', fid::text);
end;
$$;

-- Clear usage events of one kind before a date (e.g. old sign-in counts). Returns how many were removed.
create function public.admin_purge_events(kind text, before date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare n int;
begin
  perform public.require_admin();
  if before is null then raise exception 'Choose a date'; end if;
  delete from public.events where (kind is null or event = kind) and (created_at at time zone 'Asia/Jakarta')::date < before;
  get diagnostics n = row_count;
  perform public.admin_note('purge events', coalesce(kind, 'all'), jsonb_build_object('before', before, 'removed', n));
  return n;
end;
$$;

revoke execute on function public.admin_update_user(uuid, text), public.admin_delete_user(uuid),
  public.admin_update_session(uuid, text, text, boolean, boolean), public.admin_delete_session(uuid),
  public.admin_update_player(uuid, text, int), public.admin_delete_player(uuid),
  public.admin_feedback(bigint, boolean), public.admin_delete_feedback(bigint), public.admin_purge_events(text, date)
  from public, anon;
grant execute on function public.admin_update_user(uuid, text), public.admin_delete_user(uuid),
  public.admin_update_session(uuid, text, text, boolean, boolean), public.admin_delete_session(uuid),
  public.admin_update_player(uuid, text, int), public.admin_delete_player(uuid),
  public.admin_feedback(bigint, boolean), public.admin_delete_feedback(bigint), public.admin_purge_events(text, date)
  to authenticated;
