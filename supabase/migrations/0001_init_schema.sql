-- 0001_init_schema.sql
-- TEXX SOCIAL core schema.
--
-- IMPORTANT: This migration is written to be NON-DESTRUCTIVE against the live
-- production database (project iwnbsslhdqqhoocmfrik). Every statement uses
-- `if not exists` / `create or replace` so it can be safely applied on top of
-- whatever already exists in production without dropping or truncating data.
-- Table and column names match exactly what the live frontend (public/js/app.js)
-- already sends to PostgREST, so this migration documents + formalizes the
-- existing implicit contract rather than inventing a new one.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- profiles: one row per auth.users row. Created automatically by the
-- handle_new_user trigger (see 0003_age_verification.sql) from signUp()
-- metadata {username, birth_date}.
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null,
  display_name text,
  avatar_url text,
  bio text,
  website_url text,
  birth_date date,
  account_status text not null default 'active',
  role text not null default 'user',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_format check (username ~ '^[A-Za-z0-9_]{3,24}$'),
  constraint profiles_account_status_check check (account_status in ('active', 'deactivated', 'suspended', 'banned')),
  constraint profiles_role_check check (role in ('user', 'moderator', 'admin')),
  constraint profiles_bio_length check (bio is null or char_length(bio) <= 500),
  constraint profiles_website_scheme check (website_url is null or website_url ~* '^https?://')
);

create unique index if not exists profiles_username_key on public.profiles (lower(username));

-- ---------------------------------------------------------------------------
-- posts: photo/video posts and reels (post_kind distinguishes them).
-- ---------------------------------------------------------------------------
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  media_url text not null,
  storage_path text not null,
  media_type text not null,
  post_kind text not null default 'post',
  caption text,
  cover_url text,
  cover_storage_path text,
  music_provider text,
  music_url text,
  music_title text,
  music_artist text,
  music_preview_url text,
  music_clip_start integer,
  music_clip_duration integer,
  music_artwork_url text,
  status text not null default 'published',
  view_count bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint posts_media_type_check check (media_type in ('image', 'video')),
  constraint posts_post_kind_check check (post_kind in ('post', 'reel')),
  constraint posts_status_check check (status in ('published', 'removed', 'under_review')),
  constraint posts_caption_length check (caption is null or char_length(caption) <= 2200),
  constraint posts_music_provider_check check (
    music_provider is null or music_provider in ('apple_music', 'spotify', 'youtube_music', 'soundcloud', 'other')
  ),
  constraint posts_music_url_scheme check (music_url is null or music_url ~* '^https?://'),
  constraint posts_music_preview_url_scheme check (music_preview_url is null or music_preview_url ~* '^https?://'),
  constraint posts_music_clip_start_range check (music_clip_start is null or music_clip_start between 0 and 3600),
  constraint posts_music_clip_duration_range check (music_clip_duration is null or music_clip_duration between 1 and 60)
);

create index if not exists posts_user_id_created_at_idx on public.posts (user_id, created_at desc);
create index if not exists posts_created_at_idx on public.posts (created_at desc);
create index if not exists posts_post_kind_created_at_idx on public.posts (post_kind, created_at desc) where status = 'published';

-- ---------------------------------------------------------------------------
-- media: optional normalized table for future multi-asset posts / carousels.
-- The current frontend embeds media directly on posts (single asset per
-- post), so this table is additive infrastructure for that future need and
-- is not yet written to by the live client.
-- ---------------------------------------------------------------------------
create table if not exists public.media (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  post_id uuid references public.posts (id) on delete cascade,
  storage_key text not null,
  media_type text not null,
  mime_type text,
  size_bytes bigint,
  width integer,
  height integer,
  duration_seconds numeric,
  thumbnail_url text,
  processing_status text not null default 'ready',
  created_at timestamptz not null default now(),
  constraint media_media_type_check check (media_type in ('image', 'video')),
  constraint media_processing_status_check check (processing_status in ('pending', 'processing', 'ready', 'failed'))
);

create index if not exists media_post_id_idx on public.media (post_id);
create index if not exists media_owner_id_idx on public.media (owner_id);

-- ---------------------------------------------------------------------------
-- follows
-- ---------------------------------------------------------------------------
create table if not exists public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  following_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  constraint follows_no_self_follow check (follower_id <> following_id)
);

create index if not exists follows_following_id_idx on public.follows (following_id);
create index if not exists follows_follower_id_idx on public.follows (follower_id);

-- ---------------------------------------------------------------------------
-- likes
-- ---------------------------------------------------------------------------
create table if not exists public.likes (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create index if not exists likes_post_id_idx on public.likes (post_id);
create index if not exists likes_user_id_idx on public.likes (user_id);

-- ---------------------------------------------------------------------------
-- comments
-- ---------------------------------------------------------------------------
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  parent_comment_id uuid references public.comments (id) on delete cascade,
  body text not null,
  status text not null default 'published',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint comments_body_length check (char_length(body) between 1 and 500),
  constraint comments_status_check check (status in ('published', 'removed'))
);

create index if not exists comments_post_id_created_at_idx on public.comments (post_id, created_at);
create index if not exists comments_user_id_idx on public.comments (user_id);

-- ---------------------------------------------------------------------------
-- saved_posts (bookmarks) -- not yet exposed in the current UI, but part of
-- the standard social feature set called for in the product brief.
-- ---------------------------------------------------------------------------
create table if not exists public.saved_posts (
  user_id uuid not null references public.profiles (id) on delete cascade,
  post_id uuid not null references public.posts (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);

create index if not exists saved_posts_user_id_idx on public.saved_posts (user_id);

-- ---------------------------------------------------------------------------
-- direct_threads / direct_messages
-- ---------------------------------------------------------------------------
create table if not exists public.direct_threads (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references public.profiles (id) on delete cascade,
  user_b uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint direct_threads_distinct_users check (user_a <> user_b),
  constraint direct_threads_ordered_pair check (user_a < user_b)
);

-- One thread per unordered pair of users. The app always calls
-- getOrCreateThread() with the pair sorted, and this constraint plus
-- direct_threads_ordered_pair guarantees it server-side too.
create unique index if not exists direct_threads_pair_key on public.direct_threads (user_a, user_b);

create table if not exists public.direct_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.direct_threads (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  body text,
  media_url text,
  storage_path text,
  media_type text,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint direct_messages_has_content check (
    (body is not null and char_length(body) > 0) or media_url is not null
  ),
  constraint direct_messages_body_length check (body is null or char_length(body) <= 2000)
);

create index if not exists direct_messages_thread_id_created_at_idx on public.direct_messages (thread_id, created_at);
create index if not exists direct_messages_sender_id_idx on public.direct_messages (sender_id);

-- ---------------------------------------------------------------------------
-- conversation_members: normalizes direct_threads (user_a/user_b) into a
-- membership table so the messaging model can grow beyond 1:1 DMs (group
-- threads) without a breaking schema change. Backfilled by a trigger so the
-- existing 1:1 thread model keeps working unmodified.
-- ---------------------------------------------------------------------------
create table if not exists public.conversation_members (
  thread_id uuid not null references public.direct_threads (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  last_read_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (thread_id, user_id)
);

create or replace function public.sync_conversation_members()
returns trigger
language plpgsql
as $$
begin
  insert into public.conversation_members (thread_id, user_id)
  values (new.id, new.user_a), (new.id, new.user_b)
  on conflict (thread_id, user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists direct_threads_sync_members on public.direct_threads;
create trigger direct_threads_sync_members
  after insert on public.direct_threads
  for each row execute function public.sync_conversation_members();

-- Backfill for any threads that already existed before this migration ran.
insert into public.conversation_members (thread_id, user_id)
select id, user_a from public.direct_threads
on conflict do nothing;
insert into public.conversation_members (thread_id, user_id)
select id, user_b from public.direct_threads
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- live_sessions
-- ---------------------------------------------------------------------------
create table if not exists public.live_sessions (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles (id) on delete cascade,
  title text,
  status text not null default 'live',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  constraint live_sessions_status_check check (status in ('live', 'ended')),
  constraint live_sessions_title_length check (title is null or char_length(title) <= 80)
);

create index if not exists live_sessions_status_idx on public.live_sessions (status) where status = 'live';
create index if not exists live_sessions_host_id_idx on public.live_sessions (host_id);

-- ---------------------------------------------------------------------------
-- blocks: not yet exposed in the current UI. Required infrastructure for the
-- moderation model (Phase 15/16) and referenced by the feed/search/messaging
-- RLS policies in 0002_security_rls.sql.
-- ---------------------------------------------------------------------------
create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocks_no_self_block check (blocker_id <> blocked_id)
);

create index if not exists blocks_blocked_id_idx on public.blocks (blocked_id);

-- ---------------------------------------------------------------------------
-- reports: content + account reports. The live client only sends post_id
-- reports today; target_user_id/target_comment_id are additive columns for
-- account-level and comment-level reporting called for by the brief.
-- ---------------------------------------------------------------------------
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  post_id uuid references public.posts (id) on delete cascade,
  comment_id uuid references public.comments (id) on delete cascade,
  target_user_id uuid references public.profiles (id) on delete cascade,
  reason text not null,
  details text,
  status text not null default 'open',
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  constraint reports_has_target check (
    post_id is not null or comment_id is not null or target_user_id is not null
  ),
  constraint reports_status_check check (status in ('open', 'in_review', 'actioned', 'dismissed')),
  constraint reports_details_length check (details is null or char_length(details) <= 1000)
);

create index if not exists reports_status_created_at_idx on public.reports (status, created_at);
create index if not exists reports_post_id_idx on public.reports (post_id);

-- ---------------------------------------------------------------------------
-- notifications: not yet exposed in the current UI. Populated by triggers in
-- 0004_moderation_blocking_notifications.sql on follow/like/comment/message.
-- ---------------------------------------------------------------------------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  actor_id uuid references public.profiles (id) on delete set null,
  type text not null,
  post_id uuid references public.posts (id) on delete cascade,
  comment_id uuid references public.comments (id) on delete cascade,
  thread_id uuid references public.direct_threads (id) on delete cascade,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint notifications_type_check check (
    type in ('follow', 'like', 'comment', 'message', 'mention', 'report_resolved')
  )
);

create index if not exists notifications_recipient_unread_idx
  on public.notifications (recipient_id, created_at desc)
  where read_at is null;
create index if not exists notifications_recipient_created_at_idx
  on public.notifications (recipient_id, created_at desc);

-- updated_at maintenance -----------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists posts_set_updated_at on public.posts;
create trigger posts_set_updated_at before update on public.posts
  for each row execute function public.set_updated_at();

drop trigger if exists comments_set_updated_at on public.comments;
create trigger comments_set_updated_at before update on public.comments
  for each row execute function public.set_updated_at();
