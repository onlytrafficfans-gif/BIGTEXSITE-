-- 0007_account_lifecycle.sql
-- Account management (Phase 16): deactivate / reactivate self-service via
-- RPC (no elevated privileges needed). Full deletion needs the
-- auth.admin API and therefore lives in the delete-account Edge Function
-- (supabase/functions/delete-account) -- see docs/API.md.

create or replace function public.deactivate_my_account()
returns void
language sql
security definer
set search_path = public
as $$
  update public.profiles_data
  set account_status = 'deactivated'
  where id = auth.uid();
$$;

revoke all on function public.deactivate_my_account() from public;
grant execute on function public.deactivate_my_account() to authenticated;

create or replace function public.reactivate_my_account()
returns void
language sql
security definer
set search_path = public
as $$
  update public.profiles_data
  set account_status = 'active'
  where id = auth.uid() and account_status = 'deactivated';
$$;

revoke all on function public.reactivate_my_account() from public;
grant execute on function public.reactivate_my_account() to authenticated;

-- A deactivated or banned account's content drops out of the feed/discover
-- surfaces without deleting anything, so reactivation restores it exactly.
drop policy if exists posts_select on public.posts;
create policy posts_select on public.posts
  for select using (
    status = 'published'
    and exists (select 1 from public.profiles_data pr where pr.id = posts.user_id and pr.account_status = 'active')
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = posts.user_id)
         or (b.blocker_id = posts.user_id and b.blocked_id = auth.uid())
    )
  );
