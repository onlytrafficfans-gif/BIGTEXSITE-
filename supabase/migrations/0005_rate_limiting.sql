-- 0005_rate_limiting.sql
-- Database-level rate limiting (Phase 20). This runs inside the same
-- transaction as the write it's guarding, so it works no matter which
-- client hits PostgREST directly -- it cannot be bypassed by skipping the
-- frontend the way a purely client-side cooldown could be.

create table if not exists public.rate_limit_events (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  action text not null,
  created_at timestamptz not null default now()
);

create index if not exists rate_limit_events_lookup_idx
  on public.rate_limit_events (user_id, action, created_at desc);

-- Opportunistic cleanup so this table never grows unbounded; cheap because
-- it only scans rows older than the retention window via the index above.
create or replace function public.enforce_rate_limit(
  p_action text,
  p_max_count integer,
  p_window interval
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_count integer;
begin
  if v_user is null then
    raise exception 'Not authenticated.';
  end if;

  delete from public.rate_limit_events
  where user_id = v_user and action = p_action and created_at < now() - p_window;

  select count(*) into v_count
  from public.rate_limit_events
  where user_id = v_user and action = p_action and created_at >= now() - p_window;

  if v_count >= p_max_count then
    raise exception 'You are doing that too often. Please slow down and try again shortly.'
      using errcode = 'P0001';
  end if;

  insert into public.rate_limit_events (user_id, action) values (v_user, p_action);
end;
$$;

revoke all on function public.enforce_rate_limit(text, integer, interval) from public;
grant execute on function public.enforce_rate_limit(text, integer, interval) to authenticated;

-- Trigger wrapper so limits apply automatically on every insert, matching
-- limits called out in Phase 20 of the product brief.
create or replace function public.rate_limit_posts()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.enforce_rate_limit('posts:' || new.user_id, 10, interval '10 minutes'); return new; end; $$;
drop trigger if exists posts_rate_limit on public.posts;
create trigger posts_rate_limit before insert on public.posts
  for each row execute function public.rate_limit_posts();

create or replace function public.rate_limit_comments()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.enforce_rate_limit('comments:' || new.user_id, 30, interval '5 minutes'); return new; end; $$;
drop trigger if exists comments_rate_limit on public.comments;
create trigger comments_rate_limit before insert on public.comments
  for each row execute function public.rate_limit_comments();

create or replace function public.rate_limit_likes()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.enforce_rate_limit('likes:' || new.user_id, 120, interval '5 minutes'); return new; end; $$;
drop trigger if exists likes_rate_limit on public.likes;
create trigger likes_rate_limit before insert on public.likes
  for each row execute function public.rate_limit_likes();

create or replace function public.rate_limit_follows()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.enforce_rate_limit('follows:' || new.follower_id, 60, interval '10 minutes'); return new; end; $$;
drop trigger if exists follows_rate_limit on public.follows;
create trigger follows_rate_limit before insert on public.follows
  for each row execute function public.rate_limit_follows();

create or replace function public.rate_limit_messages()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.enforce_rate_limit('messages:' || new.sender_id, 60, interval '1 minute'); return new; end; $$;
drop trigger if exists direct_messages_rate_limit on public.direct_messages;
create trigger direct_messages_rate_limit before insert on public.direct_messages
  for each row execute function public.rate_limit_messages();

create or replace function public.rate_limit_reports()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.enforce_rate_limit('reports:' || new.reporter_id, 20, interval '1 hour'); return new; end; $$;
drop trigger if exists reports_rate_limit on public.reports;
create trigger reports_rate_limit before insert on public.reports
  for each row execute function public.rate_limit_reports();
