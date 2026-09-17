-- 0002_security_rls.sql
-- Row Level Security for every table. Before this migration, the live app
-- talks to Postgres with a public "publishable" key and NOTHING stops one
-- user from reading/writing another user's rows except whatever policies
-- already exist in production (unknown/unverified -- see docs/SITE_AUDIT.md).
-- Every policy below is written to match exactly what public/js/app.js
-- already does, so turning RLS on does not change any working behavior --
-- it only closes the gaps (IDOR, cross-account writes, DOB exposure).
--
-- RLS policies only ever narrow what a role can already reach -- they grant
-- nothing on their own. A hosted Supabase project's `anon`/`authenticated`
-- roles are given baseline table privileges on the `public` schema by the
-- platform itself, but this migration does not assume that (it must also
-- work standalone, e.g. against a plain self-hosted Postgres), so the
-- baseline table-level grants are made explicit here too. RLS remains the
-- real access control; these grants just make sure it has something to
-- filter.
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on all tables in schema public to anon;
grant usage, select on all sequences in schema public to authenticated;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant select on tables to anon;

-- ---------------------------------------------------------------------------
-- profiles: mask birth_date from everyone except the row owner.
--
-- PostgREST resolves `.from('profiles')` to whatever object in `public` is
-- named `profiles`. RLS alone is row-level, not column-level, so to hide
-- birth_date from other users while keeping the exact same endpoint name the
-- frontend already calls, the base table is kept under the hood and
-- `public.profiles` becomes a view with birth_date nulled out for non-owners.
-- INSTEAD OF triggers make the view fully writable so every existing
-- .insert()/.update() call in app.js keeps working unmodified.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'profiles' and c.relkind = 'r'
  ) then
    execute 'alter table public.profiles rename to profiles_data';
  end if;
end $$;

alter table public.profiles_data enable row level security;

drop policy if exists profiles_data_select_all on public.profiles_data;
create policy profiles_data_select_all on public.profiles_data
  for select using (true);

drop policy if exists profiles_data_insert_self on public.profiles_data;
create policy profiles_data_insert_self on public.profiles_data
  for insert with check (id = auth.uid());

drop policy if exists profiles_data_update_self on public.profiles_data;
create policy profiles_data_update_self on public.profiles_data
  for update using (id = auth.uid()) with check (id = auth.uid());

create or replace view public.profiles
  with (security_invoker = true)
  as
  select
    id,
    username,
    display_name,
    avatar_url,
    bio,
    website_url,
    case when id = auth.uid() then birth_date else null end as birth_date,
    account_status,
    role,
    created_at,
    updated_at
  from public.profiles_data;

create or replace function public.profiles_view_insert()
returns trigger
language plpgsql
security invoker
as $$
begin
  insert into public.profiles_data (
    id, username, display_name, avatar_url, bio, website_url,
    birth_date, account_status, role
  ) values (
    coalesce(new.id, auth.uid()), new.username, new.display_name, new.avatar_url,
    new.bio, new.website_url, new.birth_date,
    coalesce(new.account_status, 'active'), coalesce(new.role, 'user')
  );
  return new;
end;
$$;

create or replace function public.profiles_view_update()
returns trigger
language plpgsql
security invoker
as $$
begin
  update public.profiles_data set
    username = coalesce(new.username, username),
    display_name = new.display_name,
    avatar_url = new.avatar_url,
    bio = new.bio,
    website_url = new.website_url,
    birth_date = coalesce(new.birth_date, birth_date),
    account_status = coalesce(new.account_status, account_status),
    updated_at = now()
  where id = old.id;
  return new;
end;
$$;

drop trigger if exists profiles_view_insert_trg on public.profiles;
create trigger profiles_view_insert_trg
  instead of insert on public.profiles
  for each row execute function public.profiles_view_insert();

drop trigger if exists profiles_view_update_trg on public.profiles;
create trigger profiles_view_update_trg
  instead of update on public.profiles
  for each row execute function public.profiles_view_update();

grant select, insert, update on public.profiles to authenticated, anon;

-- ---------------------------------------------------------------------------
-- posts
-- ---------------------------------------------------------------------------
alter table public.posts enable row level security;

drop policy if exists posts_select on public.posts;
create policy posts_select on public.posts
  for select using (
    status = 'published'
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = posts.user_id)
         or (b.blocker_id = posts.user_id and b.blocked_id = auth.uid())
    )
  );

drop policy if exists posts_insert_self on public.posts;
create policy posts_insert_self on public.posts
  for insert with check (user_id = auth.uid());

drop policy if exists posts_update_self on public.posts;
create policy posts_update_self on public.posts
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists posts_delete_self on public.posts;
create policy posts_delete_self on public.posts
  for delete using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- media
-- ---------------------------------------------------------------------------
alter table public.media enable row level security;

drop policy if exists media_select on public.media;
create policy media_select on public.media
  for select using (
    exists (select 1 from public.posts p where p.id = media.post_id and p.status = 'published')
    or owner_id = auth.uid()
  );

drop policy if exists media_write_self on public.media;
create policy media_write_self on public.media
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- follows
-- ---------------------------------------------------------------------------
alter table public.follows enable row level security;

drop policy if exists follows_select on public.follows;
create policy follows_select on public.follows for select using (true);

drop policy if exists follows_insert_self on public.follows;
create policy follows_insert_self on public.follows
  for insert with check (
    follower_id = auth.uid()
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = following_id)
         or (b.blocker_id = following_id and b.blocked_id = auth.uid())
    )
  );

drop policy if exists follows_delete_self on public.follows;
create policy follows_delete_self on public.follows
  for delete using (follower_id = auth.uid());

-- ---------------------------------------------------------------------------
-- likes
-- ---------------------------------------------------------------------------
alter table public.likes enable row level security;

drop policy if exists likes_select on public.likes;
create policy likes_select on public.likes for select using (true);

drop policy if exists likes_insert_self on public.likes;
create policy likes_insert_self on public.likes
  for insert with check (user_id = auth.uid());

drop policy if exists likes_delete_self on public.likes;
create policy likes_delete_self on public.likes
  for delete using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- comments
-- ---------------------------------------------------------------------------
alter table public.comments enable row level security;

drop policy if exists comments_select on public.comments;
create policy comments_select on public.comments
  for select using (status = 'published');

drop policy if exists comments_insert_self on public.comments;
create policy comments_insert_self on public.comments
  for insert with check (user_id = auth.uid());

drop policy if exists comments_update_own_or_mod on public.comments;
create policy comments_update_own_or_mod on public.comments
  for update using (
    user_id = auth.uid()
    or exists (select 1 from public.profiles_data p where p.id = auth.uid() and p.role in ('moderator', 'admin'))
  );

drop policy if exists comments_delete_own_post_owner_or_mod on public.comments;
create policy comments_delete_own_post_owner_or_mod on public.comments
  for delete using (
    user_id = auth.uid()
    or exists (select 1 from public.posts p where p.id = comments.post_id and p.user_id = auth.uid())
    or exists (select 1 from public.profiles_data p where p.id = auth.uid() and p.role in ('moderator', 'admin'))
  );

-- ---------------------------------------------------------------------------
-- saved_posts
-- ---------------------------------------------------------------------------
alter table public.saved_posts enable row level security;

drop policy if exists saved_posts_owner_only on public.saved_posts;
create policy saved_posts_owner_only on public.saved_posts
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- direct_threads / conversation_members / direct_messages
-- A user may only see a thread, its members, or its messages when they are a
-- member of that thread -- never derived from a client-supplied id.
-- ---------------------------------------------------------------------------
alter table public.direct_threads enable row level security;

drop policy if exists direct_threads_members_only on public.direct_threads;
create policy direct_threads_members_only on public.direct_threads
  for select using (auth.uid() in (user_a, user_b));

drop policy if exists direct_threads_insert_self on public.direct_threads;
create policy direct_threads_insert_self on public.direct_threads
  for insert with check (
    auth.uid() in (user_a, user_b)
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = user_a and b.blocked_id = user_b)
         or (b.blocker_id = user_b and b.blocked_id = user_a)
    )
  );

-- A policy on conversation_members that queries conversation_members to
-- decide "are you a member of this thread" recurses infinitely -- Postgres
-- re-evaluates the same RLS policy for the inner query. The fix used
-- throughout Supabase for this exact shape is a SECURITY DEFINER helper:
-- it runs as the function owner (a superuser role in practice, which
-- bypasses RLS), so the membership check itself never re-triggers RLS.
create or replace function public.is_conversation_member(p_thread_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.conversation_members
    where thread_id = p_thread_id and user_id = auth.uid()
  );
$$;

grant execute on function public.is_conversation_member(uuid) to authenticated;

alter table public.conversation_members enable row level security;

drop policy if exists conversation_members_self on public.conversation_members;
create policy conversation_members_self on public.conversation_members
  for select using (
    user_id = auth.uid()
    or public.is_conversation_member(thread_id)
  );

drop policy if exists conversation_members_update_self on public.conversation_members;
create policy conversation_members_update_self on public.conversation_members
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table public.direct_messages enable row level security;

drop policy if exists direct_messages_members_only on public.direct_messages;
create policy direct_messages_members_only on public.direct_messages
  for select using (public.is_conversation_member(thread_id));

drop policy if exists direct_messages_insert_member on public.direct_messages;
create policy direct_messages_insert_member on public.direct_messages
  for insert with check (
    sender_id = auth.uid() and public.is_conversation_member(thread_id)
  );

-- ---------------------------------------------------------------------------
-- live_sessions
-- ---------------------------------------------------------------------------
alter table public.live_sessions enable row level security;

drop policy if exists live_sessions_select on public.live_sessions;
create policy live_sessions_select on public.live_sessions for select using (true);

drop policy if exists live_sessions_insert_self on public.live_sessions;
create policy live_sessions_insert_self on public.live_sessions
  for insert with check (host_id = auth.uid());

drop policy if exists live_sessions_update_self on public.live_sessions;
create policy live_sessions_update_self on public.live_sessions
  for update using (host_id = auth.uid()) with check (host_id = auth.uid());

-- ---------------------------------------------------------------------------
-- blocks
-- ---------------------------------------------------------------------------
alter table public.blocks enable row level security;

drop policy if exists blocks_select_self on public.blocks;
create policy blocks_select_self on public.blocks
  for select using (blocker_id = auth.uid());

drop policy if exists blocks_insert_self on public.blocks;
create policy blocks_insert_self on public.blocks
  for insert with check (blocker_id = auth.uid());

drop policy if exists blocks_delete_self on public.blocks;
create policy blocks_delete_self on public.blocks
  for delete using (blocker_id = auth.uid());

-- ---------------------------------------------------------------------------
-- reports: reporters can create + see their own reports; moderators see all.
-- ---------------------------------------------------------------------------
alter table public.reports enable row level security;

drop policy if exists reports_select_own_or_mod on public.reports;
create policy reports_select_own_or_mod on public.reports
  for select using (
    reporter_id = auth.uid()
    or exists (select 1 from public.profiles_data p where p.id = auth.uid() and p.role in ('moderator', 'admin'))
  );

drop policy if exists reports_insert_self on public.reports;
create policy reports_insert_self on public.reports
  for insert with check (reporter_id = auth.uid());

drop policy if exists reports_update_mod_only on public.reports;
create policy reports_update_mod_only on public.reports
  for update using (
    exists (select 1 from public.profiles_data p where p.id = auth.uid() and p.role in ('moderator', 'admin'))
  );

-- ---------------------------------------------------------------------------
-- notifications
-- ---------------------------------------------------------------------------
alter table public.notifications enable row level security;

drop policy if exists notifications_select_self on public.notifications;
create policy notifications_select_self on public.notifications
  for select using (recipient_id = auth.uid());

drop policy if exists notifications_update_self on public.notifications;
create policy notifications_update_self on public.notifications
  for update using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());

-- notifications are only ever inserted by SECURITY DEFINER triggers (see
-- 0004_moderation_blocking_notifications.sql), never directly by clients.
