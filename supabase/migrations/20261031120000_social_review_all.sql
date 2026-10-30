-- Threads agent: nothing goes out without the admin's approval, not even replies to comments on our own posts
-- or the daily post. Every draft lands in the review queue; the old auto_* settings no longer have any effect.

update public.social_config set auto_own_replies = false, auto_post = false where id = 1;
alter table public.social_config alter column auto_own_replies set default false, alter column auto_post set default false;

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
    select i ->> 'kind', 'draft',
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
