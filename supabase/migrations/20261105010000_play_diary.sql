-- Play diary ("Main sendiri"): a player logs their own games while playing (win or lose, optional score,
-- what went well and what didn't, a note), then finishes the session and gets a summary with tips.
-- One row per playing session; games are a JSON array, like sessions.rounds. Private to its owner.

create table public.plays (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  place text check (char_length(place) <= 120),
  -- [{at, res: 'W' | 'L', me, opp, good: [tag], bad: [tag], note}]
  games jsonb not null default '[]' check (jsonb_typeof(games) = 'array' and jsonb_array_length(games) <= 60
    and pg_column_size(games) < 65536),
  lesson text check (char_length(lesson) <= 280),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index plays_user_started_idx on public.plays (user_id, started_at desc);

alter table public.plays enable row level security;
create policy "Users read own plays" on public.plays
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users create own plays" on public.plays
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users update own plays" on public.plays
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Users delete own plays" on public.plays
  for delete to authenticated using ((select auth.uid()) = user_id);
revoke all on public.plays from anon;

create trigger plays_touch_updated_at
  before update on public.plays
  for each row execute function public.touch_updated_at();

-- What usually costs the player points, picked during onboarding (max 2 tags).
alter table public.profiles add column weak_tags text[] check (weak_tags is null or cardinality(weak_tags) <= 2);

-- Guest merge also moves the play diary and the onboarding answers.
create or replace function public.finish_guest_merge(t text)
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

  update public.sessions set user_id = uid where user_id = g;
  update public.session_shares set owner_id = uid where owner_id = g;
  update public.feedback set user_id = uid where user_id = g;
  update public.plays set user_id = uid where user_id = g;
  update public.profiles set weak_tags = coalesce(public.profiles.weak_tags, (select weak_tags from public.profiles where id = g))
    where id = uid;

  for r in select id, name from public.players where owner_id = g and merged_into is null loop
    select id into d from public.players where owner_id = uid and lower(name) = lower(r.name) and merged_into is null;
    if d is not null then perform public.merge_players(r.id, d);
    else update public.players set owner_id = uid where id = r.id; end if;
  end loop;
  insert into public.rosters (owner_id, player_id) select uid, player_id from public.rosters where owner_id = g
    on conflict do nothing;
  delete from public.rosters where owner_id = g;

  select id into gp from public.players where user_id = g and merged_into is null;
  if gp is not null then
    select id into mp from public.players where user_id = uid and merged_into is null;
    if mp is null then
      update public.players set user_id = uid where id = gp;
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

-- Idle guests: a guest with a play diary has kept something.
create or replace function public.purge_idle_guests()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare n int;
begin
  delete from auth.users u where u.is_anonymous and u.created_at < now() - interval '30 days'
    and not exists (select 1 from public.sessions s where s.user_id = u.id)
    and not exists (select 1 from public.plays p where p.user_id = u.id)
    and not exists (select 1 from public.rosters r where r.owner_id = u.id)
    and not exists (select 1 from public.players p where p.user_id = u.id);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.purge_idle_guests() from public, anon, authenticated;

-- Admin: play diary counts, next to the existing numbers.
create function public.admin_play_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'plays', (select count(*) from public.plays),
    'plays_7d', (select count(*) from public.plays where started_at > now() - interval '7 days'),
    'players_7d', (select count(distinct user_id) from public.plays where started_at > now() - interval '7 days'),
    'games', (select coalesce(sum(jsonb_array_length(games)), 0) from public.plays));
end;
$$;
revoke execute on function public.admin_play_stats() from public, anon;
grant execute on function public.admin_play_stats() to authenticated;
