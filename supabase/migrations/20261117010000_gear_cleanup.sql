-- Gear revamp, still 0.12: no "Pensiunkan" (retire) and no photos from the player. Pictures now come with the
-- catalog (/img/gear/<id>.webp in the app), so the photo columns, the retired flag and the `gear` bucket go.

alter table public.rackets
  drop column if exists photo,
  drop column if exists string_photo,
  drop column if exists retired;

drop policy if exists "Users manage their own gear photos (insert)" on storage.objects;
drop policy if exists "Users manage their own gear photos (update)" on storage.objects;
drop policy if exists "Users manage their own gear photos (delete)" on storage.objects;
drop policy if exists "Users read their own gear photo objects" on storage.objects;

-- Remove the bucket when it is empty. Supabase may refuse deleting storage rows from SQL (or a test photo may still
-- be in it); then this only leaves a notice, and the bucket can be deleted in the dashboard (Storage → gear → Delete).
do $$
begin
  delete from storage.buckets where id = 'gear';
exception when others then
  raise notice 'gear bucket not removed: %', sqlerrm;
end;
$$;
