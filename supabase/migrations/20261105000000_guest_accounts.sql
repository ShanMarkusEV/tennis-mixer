-- Guest accounts: phones without Google sign-in get a Supabase anonymous user the first time they have
-- something to keep, so their sessions, roster and claims live on the server like everyone's.
-- "Save to Google" links Google to the same user (same id, nothing moves). When that Google account already
-- has 10nis, or a guest moves from an in-app browser to Chrome/Safari, a one-time merge token moves the guest's
-- data into the other account.

-- ---------- merge tokens ----------
create table public.guest_merges (
  token text primary key,
  guest_id uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '1 day'
);
alter table public.guest_merges enable row level security;   -- only reachable through the functions below
revoke all on public.guest_merges from anon, authenticated;

-- Guest: get a token that lets whoever signs in next (on this or another browser) take over this guest's data.
create function public.begin_guest_merge()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  t text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not coalesce((select is_anonymous from auth.users where id = uid), false) then raise exception 'Already saved to Google'; end if;
  delete from public.guest_merges where guest_id = uid or expires_at < now();
  insert into public.guest_merges (token, guest_id) values (t, uid);
  return t;
end;
$$;
revoke execute on function public.begin_guest_merge() from public, anon;
grant execute on function public.begin_guest_merge() to authenticated;

-- Move everything a guest owns into the caller's account, then delete the guest.
-- Returns the guest's id (so the app can re-own its open session), or null when there was nothing to move
-- (the token was used, expired, or belongs to the caller, e.g. after Google was linked to the same user).
create function public.finish_guest_merge(t text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  g uuid;
  r record;
  d uuid;
  gp uuid;
  mp uuid;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  delete from public.guest_merges where token = t and expires_at > now() returning guest_id into g;
  if g is null or g = uid then return null; end if;
  if not coalesce((select is_anonymous from auth.users where id = g), false) then return null; end if;

  -- Sessions and their share links.
  update public.sessions set user_id = uid where user_id = g;
  update public.session_shares set owner_id = uid where owner_id = g;
  update public.feedback set user_id = uid where user_id = g;

  -- Private roster names: the same name on both rosters becomes one player, history included.
  for r in select id, name from public.players where owner_id = g and merged_into is null loop
    select id into d from public.players where owner_id = uid and lower(name) = lower(r.name) and merged_into is null;
    if d is not null then perform public.merge_players(r.id, d);
    else update public.players set owner_id = uid where id = r.id; end if;
  end loop;
  insert into public.rosters (owner_id, player_id) select uid, player_id from public.rosters where owner_id = g
    on conflict do nothing;
  delete from public.rosters where owner_id = g;

  -- The guest's own player record (claims, self rating) joins the caller's.
  select id into gp from public.players where user_id = g and merged_into is null;
  if gp is not null then
    select id into mp from public.players where user_id = uid and merged_into is null;
    if mp is null then
      update public.players set user_id = uid where id = gp;   -- picks up the account's name and photo (trigger)
    else
      update public.players set user_id = null where id = gp;
      update public.players set self_level = coalesce(public.players.self_level, (select self_level from public.players where id = gp)) where id = mp;
      perform public.merge_players(gp, mp);
    end if;
  end if;

  delete from auth.users where id = g;
  perform public.recompute_ratings();
  return g;
end;
$$;
revoke execute on function public.finish_guest_merge(text) from public, anon;
grant execute on function public.finish_guest_merge(text) to authenticated;

-- ---------- Google linked to a guest ----------
-- The user id stays the same, so the players_account_identity trigger doesn't fire: copy the Google name and
-- photo onto the guest's player record here, unless they already chose a name.
create function public.guest_linked()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare i record;
begin
  if old.is_anonymous and not new.is_anonymous then
    select * into i from public.account_identity(new.id);
    update public.profiles set display_name = coalesce(display_name, left(nullif(trim(coalesce(
      new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name')), ''), 80)) where id = new.id;
    update public.players set
      name = case when name = 'Player' and i.name is not null then i.name else name end,
      photo = case when photo is null and i.photo ~ '^https://' then i.photo else photo end
      where user_id = new.id and merged_into is null;
  end if;
  return new;
end;
$$;
create trigger on_auth_user_linked
  after update of is_anonymous on auth.users
  for each row execute function public.guest_linked();

-- ---------- admin ----------
-- Accounts count Google users only; guests are counted separately.
create or replace function public.admin_stats()
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
    'accounts', (select count(*) from auth.users where not is_anonymous),
    'accounts_7d', (select count(*) from auth.users where not is_anonymous and created_at > now() - interval '7 days'),
    'accounts_30d', (select count(*) from auth.users where not is_anonymous and created_at > now() - interval '30 days'),
    'signed_in_7d', (select count(*) from auth.users where not is_anonymous and last_sign_in_at > now() - interval '7 days'),
    'guests', (select count(*) from auth.users where is_anonymous),
    'guests_7d', (select count(*) from auth.users where is_anonymous and created_at > now() - interval '7 days'),
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
        'signups', (select count(*) from auth.users u where not u.is_anonymous and (u.created_at at time zone 'Asia/Jakarta')::date = d.day),
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

-- Guests that never kept anything (no sessions, roster or player record) after 30 days.
-- Run by hand from the SQL editor, or schedule with pg_cron: select public.purge_idle_guests();
create function public.purge_idle_guests()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare n int;
begin
  delete from auth.users u where u.is_anonymous and u.created_at < now() - interval '30 days'
    and not exists (select 1 from public.sessions s where s.user_id = u.id)
    and not exists (select 1 from public.rosters r where r.owner_id = u.id)
    and not exists (select 1 from public.players p where p.user_id = u.id);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.purge_idle_guests() from public, anon, authenticated;
