-- The social media agent now lives elsewhere: stop its cron jobs and remove its functions, tables
-- (including the stored Threads/Instagram tokens) and the cron secret.

select cron.unschedule(jobname) from cron.job where jobname in ('social-run', 'social-news');

delete from vault.secrets where name = 'social_cron_secret';

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like any (array['social\_%', 'admin\_social\_%'])
  loop
    execute 'drop function ' || f.sig;
  end loop;
end $$;

drop table if exists public.social_queue, public.social_seen, public.social_oauth_states, public.social_config;
