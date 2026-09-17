-- 0006_storage_media.sql
-- Storage bucket + policies for the "media" bucket that public/js/app.js
-- already uploads to (posts, reels, covers, avatars, share attachments).
-- The app calls storage.from('media').getPublicUrl(path) and renders that
-- URL directly in <img>/<video> tags, so the bucket must stay public for
-- read; what needs locking down is WRITE access, which today has no
-- verified policy. Every upload path the client uses is prefixed with
-- `${auth.uid()}/...`, so policies key off that.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'media',
  'media',
  true,
  104857600, -- 100 MB ceiling; composer.js enforces 15 MB images / 100 MB video / 10 MB covers client-side, this is the hard server-side backstop
  array[
    'image/jpeg', 'image/png', 'image/webp',
    'video/mp4', 'video/quicktime', 'video/webm'
  ]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists media_public_read on storage.objects;
create policy media_public_read on storage.objects
  for select using (bucket_id = 'media');

-- Every upload path in app.js starts with the uploader's own auth.uid(), so
-- ownership is enforced by requiring that prefix rather than trusting the
-- client-supplied path.
drop policy if exists media_owner_insert on storage.objects;
create policy media_owner_insert on storage.objects
  for insert with check (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists media_owner_update on storage.objects;
create policy media_owner_update on storage.objects
  for update using (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists media_owner_delete on storage.objects;
create policy media_owner_delete on storage.objects
  for delete using (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
