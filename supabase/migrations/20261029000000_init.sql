-- Tennis Mixer: user profiles and logged mixer sessions.
-- Every row belongs to one auth user; row-level security keeps users to their own data.

-- ---------- profiles ----------
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text check (char_length(display_name) <= 80),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "Users read own profile" on public.profiles
  for select to authenticated using ((select auth.uid()) = id);
create policy "Users update own profile" on public.profiles
  for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- Create a profile automatically when someone registers.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- sessions ----------
-- One row per mixer session. players/rounds mirror the app's state:
--   players: [{id, name, active}]
--   rounds:  [{mode, matches: [{a: [id, id], b: [id, id], sa, sb}], sitting: [id]}]
create table public.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  title text check (char_length(title) <= 120),
  mode text not null default 'americano' check (mode in ('americano', 'mexicano')),
  courts int not null default 2 check (courts between 1 and 10),
  total int not null default 0 check (total >= 0),
  players jsonb not null default '[]' check (jsonb_typeof(players) = 'array'),
  rounds jsonb not null default '[]' check (jsonb_typeof(rounds) = 'array'),
  played_on date not null default current_date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index sessions_user_played_idx on public.sessions (user_id, played_on desc, created_at desc);

alter table public.sessions enable row level security;

create policy "Users read own sessions" on public.sessions
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users create own sessions" on public.sessions
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users update own sessions" on public.sessions
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Users delete own sessions" on public.sessions
  for delete to authenticated using ((select auth.uid()) = user_id);

create function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger sessions_touch_updated_at
  before update on public.sessions
  for each row execute function public.touch_updated_at();

-- Signed-out visitors get nothing.
revoke all on public.profiles, public.sessions from anon;
