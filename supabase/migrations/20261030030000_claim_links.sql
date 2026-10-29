-- Share links: an organizer shares https://10nis.win/s/<token> (or its QR) for a logged session, and each
-- player signs in and taps their own name. That roster name is then linked to their 10nis account, so the
-- session's results (and every later session where the organizer uses the same name) count for them.

create table public.session_shares (
  token text primary key,
  session_id uuid not null references public.sessions on delete cascade,
  owner_id uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days'
);
create index session_shares_session_idx on public.session_shares (session_id);
alter table public.session_shares enable row level security;   -- only reachable through the functions below
revoke all on public.session_shares from anon, authenticated;

-- Organizer: get (or create) the share token for one of their sessions.
create function public.create_share(sid uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare t text;
begin
  if not exists (select 1 from public.sessions where id = sid and user_id = auth.uid()) then
    raise exception 'Session not found';
  end if;
  select token into t from public.session_shares where session_id = sid and expires_at > now() + interval '1 day';
  if t is null then
    t := left(replace(gen_random_uuid()::text, '-', ''), 16);
    insert into public.session_shares (token, session_id, owner_id) values (t, sid, auth.uid());
  end if;
  return t;
end;
$$;
revoke execute on function public.create_share(uuid) from public, anon;
grant execute on function public.create_share(uuid) to authenticated;

-- Anyone with the link: the session's date and the names on its roster, with who has already claimed theirs.
create function public.share_roster(t text)
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
begin
  select ss.session_id, se.played_on, se.players into s
    from public.session_shares ss join public.sessions se on se.id = ss.session_id
    where ss.token = t and ss.expires_at > now();
  if not found then return null; end if;
  for pl in select * from jsonb_array_elements(coalesce(s.players, '[]'::jsonb)) loop
    pid := null; owner := null;
    if (pl ->> 'pid') ~* '^[0-9a-f-]{36}$' then
      pid := public.resolve_player((pl ->> 'pid')::uuid);
      select user_id into owner from public.players where id = pid;
    end if;
    res := res || jsonb_build_array(jsonb_build_object(
      'local', pl ->> 'id', 'name', pl ->> 'name', 'photo', pl ->> 'photo',
      'claimable', pid is not null, 'claimed', owner is not null,
      'mine', owner is not null and owner = auth.uid()));
  end loop;
  return jsonb_build_object('played_on', s.played_on, 'players', res);
end;
$$;
revoke execute on function public.share_roster(text) from public;
grant execute on function public.share_roster(text) to anon, authenticated;

-- Signed-in player: "this name is me".
create function public.claim_name(t text, local_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  sid uuid;
  pl jsonb;
  target uuid;
  tgt record;
  me uuid;
  mine record;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  select ss.session_id into sid from public.session_shares ss where ss.token = t and ss.expires_at > now();
  if sid is null then raise exception 'This link has expired. Ask the organizer for a new one.'; end if;
  select p.value into pl from public.sessions se, jsonb_array_elements(se.players) p where se.id = sid and p.value ->> 'id' = local_id;
  if pl is null or (pl ->> 'pid') !~* '^[0-9a-f-]{36}$' then raise exception 'That name is not on this session'; end if;
  target := public.resolve_player((pl ->> 'pid')::uuid);
  select * into tgt from public.players where id = target;
  if tgt.user_id = uid then return jsonb_build_object('player_id', target, 'already', true); end if;
  if tgt.user_id is not null then raise exception 'Someone has already claimed this name'; end if;

  select id into me from public.players where user_id = uid and merged_into is null;
  if me is null then
    update public.players set user_id = uid, owner_id = null where id = target;
    me := target;
  else
    select * into mine from public.players where id = me;
    if (tgt.kuyy_id is not null and mine.kuyy_id is not null and tgt.kuyy_id <> mine.kuyy_id)
       or (tgt.reclub_id is not null and mine.reclub_id is not null and tgt.reclub_id <> mine.reclub_id) then
      raise exception 'That name belongs to a different Kuyy or Reclub profile than yours';
    end if;
    -- Carry the target's platform ids over (they are unique, so free them first), then fold it in.
    update public.players set kuyy_id = null, kuyy_username = null, reclub_id = null, reclub_username = null where id = target;
    update public.players set
      kuyy_id = coalesce(kuyy_id, tgt.kuyy_id), kuyy_username = coalesce(kuyy_username, tgt.kuyy_username),
      reclub_id = coalesce(reclub_id, tgt.reclub_id), reclub_username = coalesce(reclub_username, tgt.reclub_username),
      photo = coalesce(photo, tgt.photo)
    where id = me;
    perform public.merge_players(target, me);
  end if;
  perform public.recompute_ratings();
  return jsonb_build_object('player_id', me);
end;
$$;
revoke execute on function public.claim_name(text, text) from public, anon;
grant execute on function public.claim_name(text, text) to authenticated;
