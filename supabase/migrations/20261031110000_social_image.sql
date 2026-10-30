-- Threads agent: the daily post carries a screenshot of the app (a demo session with made-up players, served
-- from /promo on 10nis.win), picked to match the post's topic.

alter table public.social_queue add column image text check (image is null or image ~ '^promo/[a-z0-9-]+\.jpg$');

create or replace function public.social_cron_add(secret text, items jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
  cfg record;
begin
  perform public.social_require(secret);
  select * into cfg from public.social_config where id = 1;
  insert into public.social_queue (kind, status, text, target_id, target_author, target_text, target_url, query, score, reason, topic, image)
    select i ->> 'kind',
      case when (i ->> 'kind' = 'own_reply' and cfg.auto_own_replies) or (i ->> 'kind' = 'post' and cfg.auto_post)
           then 'approved' else 'draft' end,
      left(i ->> 'text', 500), i ->> 'target_id', left(i ->> 'target_author', 100), left(i ->> 'target_text', 1000),
      left(i ->> 'target_url', 300), left(i ->> 'query', 100), (i ->> 'score')::numeric, left(i ->> 'reason', 300),
      case when i ->> 'kind' = 'post' then cfg.post_topic end,
      case when i ->> 'kind' = 'post' and i ->> 'image' ~ '^promo/[a-z0-9-]+\.jpg$' then i ->> 'image' end
    from jsonb_array_elements(coalesce(items, '[]')) i
    where coalesce(i ->> 'text', '') <> '' and i ->> 'kind' in ('post', 'reply', 'own_reply')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;
