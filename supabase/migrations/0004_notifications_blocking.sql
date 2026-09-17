-- 0004_notifications_blocking.sql
-- Notification fan-out (Phase 13) and blocking enforcement (Phase 15/16).
-- The current frontend does not yet render a notifications inbox or a block
-- button; this migration builds the backend so that UI can be added without
-- any further schema work. See docs/FEATURE_STATUS.md.

create or replace function public.is_blocked_pair(a uuid, b uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

-- follow -> notify the followed user
create or replace function public.notify_on_follow()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_blocked_pair(new.follower_id, new.following_id) then
    insert into public.notifications (recipient_id, actor_id, type)
    values (new.following_id, new.follower_id, 'follow');
  end if;
  return new;
end;
$$;

drop trigger if exists follows_notify on public.follows;
create trigger follows_notify
  after insert on public.follows
  for each row execute function public.notify_on_follow();

-- like -> notify the post owner (skip self-likes)
create or replace function public.notify_on_like()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
begin
  select user_id into v_owner from public.posts where id = new.post_id;
  if v_owner is not null and v_owner <> new.user_id and not public.is_blocked_pair(v_owner, new.user_id) then
    insert into public.notifications (recipient_id, actor_id, type, post_id)
    values (v_owner, new.user_id, 'like', new.post_id);
  end if;
  return new;
end;
$$;

drop trigger if exists likes_notify on public.likes;
create trigger likes_notify
  after insert on public.likes
  for each row execute function public.notify_on_like();

-- comment -> notify the post owner (skip self-comments)
create or replace function public.notify_on_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
begin
  select user_id into v_owner from public.posts where id = new.post_id;
  if v_owner is not null and v_owner <> new.user_id and not public.is_blocked_pair(v_owner, new.user_id) then
    insert into public.notifications (recipient_id, actor_id, type, post_id, comment_id)
    values (v_owner, new.user_id, 'comment', new.post_id, new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists comments_notify on public.comments;
create trigger comments_notify
  after insert on public.comments
  for each row execute function public.notify_on_comment();

-- direct message -> notify the other thread member(s)
create or replace function public.notify_on_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notifications (recipient_id, actor_id, type, thread_id)
  select cm.user_id, new.sender_id, 'message', new.thread_id
  from public.conversation_members cm
  where cm.thread_id = new.thread_id and cm.user_id <> new.sender_id;
  return new;
end;
$$;

drop trigger if exists direct_messages_notify on public.direct_messages;
create trigger direct_messages_notify
  after insert on public.direct_messages
  for each row execute function public.notify_on_message();

-- ---------------------------------------------------------------------------
-- Blocking side effects: removing an existing follow/like relationship in
-- either direction the moment a block is created, so a block takes effect
-- immediately rather than only for future interactions.
-- ---------------------------------------------------------------------------
create or replace function public.apply_block_effects()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.follows
  where (follower_id = new.blocker_id and following_id = new.blocked_id)
     or (follower_id = new.blocked_id and following_id = new.blocker_id);

  delete from public.likes l
  using public.posts p
  where l.post_id = p.id
    and ((l.user_id = new.blocker_id and p.user_id = new.blocked_id)
      or (l.user_id = new.blocked_id and p.user_id = new.blocker_id));

  return new;
end;
$$;

drop trigger if exists blocks_apply_effects on public.blocks;
create trigger blocks_apply_effects
  after insert on public.blocks
  for each row execute function public.apply_block_effects();

-- ---------------------------------------------------------------------------
-- mark_all_notifications_read: convenience RPC backing a future "mark all
-- as read" button (Phase 13).
-- ---------------------------------------------------------------------------
create or replace function public.mark_all_notifications_read()
returns void
language sql
security definer
set search_path = public
as $$
  update public.notifications
  set read_at = now()
  where recipient_id = auth.uid() and read_at is null;
$$;

revoke all on function public.mark_all_notifications_read() from public;
grant execute on function public.mark_all_notifications_read() to authenticated;
