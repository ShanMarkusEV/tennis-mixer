-- Gear, 0.12: the player's rackets and the string in each one (string, gauge, tension, the day it was strung),
-- with the restring history and an optional photo of the racket and of the string. Picked from /gear.json or
-- typed. Private to its owner, like the play diary. A diary session can name the racket it was played with,
-- which is how the app estimates string wear (sessions × hours per session; nothing is timed).

create table public.rackets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  model_id text check (char_length(model_id) <= 80),
  name text not null check (char_length(name) between 1 and 80),
  nickname text check (char_length(nickname) <= 40),
  string_id text check (char_length(string_id) <= 80),
  string_name text check (char_length(string_name) <= 80),
  string_type text check (string_type in ('poly', 'multi', 'syn', 'gut')),
  cross_id text check (char_length(cross_id) <= 80),
  cross_name text check (char_length(cross_name) <= 80),
  cross_type text check (cross_type in ('poly', 'multi', 'syn', 'gut')),
  gauge text check (char_length(gauge) <= 8),
  tension_main numeric(4, 1) check (tension_main between 5 and 90),
  tension_cross numeric(4, 1) check (tension_cross between 5 and 90),
  tension_unit text not null default 'kg' check (tension_unit in ('kg', 'lbs')),
  strung_on date,
  restrings jsonb not null default '[]' check (jsonb_typeof(restrings) = 'array' and jsonb_array_length(restrings) <= 30
    and pg_column_size(restrings) < 16384),
  photo text check (char_length(photo) <= 400),
  string_photo text check (char_length(string_photo) <= 400),
  retired boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index rackets_user_idx on public.rackets (user_id, created_at desc);

alter table public.rackets enable row level security;
create policy "Users read own rackets" on public.rackets
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users create own rackets" on public.rackets
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users update own rackets" on public.rackets
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Users delete own rackets" on public.rackets
  for delete to authenticated using ((select auth.uid()) = user_id);
revoke all on public.rackets from anon;

create trigger rackets_touch_updated_at
  before update on public.rackets
  for each row execute function public.touch_updated_at();

-- The racket a session was played with. No foreign key on purpose: the phone may save the session before the
-- racket reaches the server, and a deleted racket just leaves a stale id that the app ignores.
alter table public.plays add column racket_id uuid;

-- ---------- photos ----------
-- Public bucket (like avatars): gear/<user id>/<racket id>-<racket|string>-<time>.webp, resized on the phone to
-- at most 800px (~50-80 KB). The paths hold unguessable ids; only the owner can write or delete.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('gear', 'gear', true, 524288, array['image/webp', 'image/jpeg'])
  on conflict (id) do update set public = true, file_size_limit = 524288, allowed_mime_types = array['image/webp', 'image/jpeg'];

create policy "Users manage their own gear photos (insert)" on storage.objects
  for insert to authenticated with check (bucket_id = 'gear' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users manage their own gear photos (update)" on storage.objects
  for update to authenticated using (bucket_id = 'gear' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users manage their own gear photos (delete)" on storage.objects
  for delete to authenticated using (bucket_id = 'gear' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users read their own gear photo objects" on storage.objects
  for select to authenticated using (bucket_id = 'gear' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Guest merge also moves the rackets (their photos stay where they are; the urls keep working).
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
  update public.coach_sessions set user_id = uid where user_id = g;
  update public.rackets set user_id = uid where user_id = g;
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

-- Idle guests: a guest with a racket has kept something.
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
    and not exists (select 1 from public.coach_sessions c where c.user_id = u.id)
    and not exists (select 1 from public.rackets k where k.user_id = u.id)
    and not exists (select 1 from public.rosters r where r.owner_id = u.id)
    and not exists (select 1 from public.players p where p.user_id = u.id);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.purge_idle_guests() from public, anon, authenticated;

-- ---------- usage events ----------
alter table public.events drop constraint events_event_check;
alter table public.events add constraint events_event_check check (event in (
  'open', 'round', 'finish', 'import', 'signin', 'install', 'error', 'join',
  'guest', 'linked', 'merged', 'open_outside', 'latihan', 'share_latihan',
  'onboard', 'play_start', 'play_game', 'play_end', 'play_share', 'les_save', 'les_pr',
  'gear_add', 'gear_restring'));

create or replace function public.track(device text, event text, props jsonb default '{}', signed_in boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if device !~ '^[0-9a-f]{16}$' or event not in ('open', 'round', 'finish', 'import', 'signin', 'install', 'error', 'join',
      'guest', 'linked', 'merged', 'open_outside', 'latihan', 'share_latihan',
      'onboard', 'play_start', 'play_game', 'play_end', 'play_share', 'les_save', 'les_pr',
      'gear_add', 'gear_restring') then return; end if;
  -- Ignore floods from one device (more than 500 events in a day).
  if (select count(*) from public.events e where e.device = track.device and e.created_at > now() - interval '1 day') >= 500 then return; end if;
  insert into public.events (device, event, signed_in, props)
    values (device, event, coalesce(signed_in, false),
            case when jsonb_typeof(props) = 'object' and pg_column_size(props) < 512 then props else '{}' end);
end;
$$;
