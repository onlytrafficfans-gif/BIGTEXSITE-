-- tests/rls.test.sql
-- Assertion-based tests for the security behavior documented in
-- docs/SECURITY.md. Run with `npm test` (see scripts/run-sql-tests.js)
-- against a database that already has tests/supabase_stub.sql and every
-- file in supabase/migrations/ applied, in order.
--
-- Each check either passes silently or RAISEs, which aborts the script
-- with a non-zero exit code -- npm test / CI fails loudly on any
-- regression instead of requiring someone to eyeball query output.

\set ON_ERROR_STOP on

do $$
begin
  raise notice 'TEXX SOCIAL RLS test suite starting';
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures: two real users signed up the same way the live app does it
-- (auth.users insert with {username, birth_date} metadata, which fires
-- handle_new_user()).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com', '{"username":"alice","birth_date":"2000-01-01"}'),
  ('22222222-2222-2222-2222-222222222222', 'bob@example.com', '{"username":"bob","birth_date":"2000-01-01"}');

-- ---------------------------------------------------------------------------
-- Age verification
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    insert into auth.users (id, email, raw_user_meta_data) values
      ('33333333-3333-3333-3333-333333333333', 'kid@example.com', '{"username":"kid","birth_date":"2018-01-01"}');
    raise exception 'TEST FAILED: underage signup should have been rejected';
  exception
    when others then
      if sqlerrm not ilike '%at least 15%' then
        raise exception 'TEST FAILED: underage signup rejected for the wrong reason: %', sqlerrm;
      end if;
      raise notice 'PASS: underage signup rejected server-side';
  end;
end $$;

do $$
begin
  begin
    update public.profiles_data set birth_date = current_date - interval '5 years'
    where id = '11111111-1111-1111-1111-111111111111';
    raise exception 'TEST FAILED: underage birth_date update should have been rejected';
  exception
    when check_violation then
      raise notice 'PASS: underage birth_date update rejected by check constraint';
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Username uniqueness
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    insert into auth.users (id, email, raw_user_meta_data) values
      ('44444444-4444-4444-4444-444444444444', 'dup@example.com', '{"username":"ALICE","birth_date":"2000-01-01"}');
    raise exception 'TEST FAILED: duplicate (case-insensitive) username should have been rejected';
  exception
    when unique_violation then
      raise notice 'PASS: duplicate username rejected';
  end;
end $$;

-- ---------------------------------------------------------------------------
-- DOB masking: only the owner sees their own birth_date via the public view
-- ---------------------------------------------------------------------------
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

do $$
declare v_dob date;
begin
  select birth_date into v_dob from public.profiles where id = '11111111-1111-1111-1111-111111111111';
  if v_dob is distinct from date '2000-01-01' then
    raise exception 'TEST FAILED: owner should see their own birth_date, got %', v_dob;
  end if;
  raise notice 'PASS: owner sees their own birth_date';
end $$;

do $$
declare v_dob date;
begin
  select birth_date into v_dob from public.profiles where id = '22222222-2222-2222-2222-222222222222';
  if v_dob is not null then
    raise exception 'TEST FAILED: non-owner should see birth_date as null, got %', v_dob;
  end if;
  raise notice 'PASS: non-owner sees birth_date masked as null';
end $$;

-- ---------------------------------------------------------------------------
-- Self-follow / self-block prevention
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    insert into public.follows (follower_id, following_id) values
      ('11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111');
    raise exception 'TEST FAILED: self-follow should have been rejected';
  exception
    when check_violation then
      raise notice 'PASS: self-follow rejected';
  end;
end $$;

-- ---------------------------------------------------------------------------
-- IDOR: a user cannot create a post as another user
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    insert into public.posts (user_id, media_url, storage_path, media_type)
    values ('22222222-2222-2222-2222-222222222222', 'http://x/b.jpg', '22222222-2222-2222-2222-222222222222/b.jpg', 'image');
    raise exception 'TEST FAILED: creating a post as another user should have been rejected by RLS';
  exception
    when insufficient_privilege then
      raise notice 'PASS: cannot create a post as another user';
  end;
end $$;

do $$
declare v_post_id uuid;
begin
  insert into public.posts (user_id, media_url, storage_path, media_type)
  values ('11111111-1111-1111-1111-111111111111', 'http://x/a.jpg', '11111111-1111-1111-1111-111111111111/a.jpg', 'image')
  returning id into v_post_id;
  if v_post_id is null then
    raise exception 'TEST FAILED: creating your own post should have succeeded';
  end if;
  raise notice 'PASS: creating your own post succeeds';
end $$;

-- ---------------------------------------------------------------------------
-- Duplicate likes blocked at the database level
-- ---------------------------------------------------------------------------
do $$
declare v_post_id uuid;
begin
  select id into v_post_id from public.posts where user_id = '11111111-1111-1111-1111-111111111111' limit 1;
  insert into public.likes (post_id, user_id) values (v_post_id, '11111111-1111-1111-1111-111111111111');
  begin
    insert into public.likes (post_id, user_id) values (v_post_id, '11111111-1111-1111-1111-111111111111');
    raise exception 'TEST FAILED: duplicate like should have been rejected';
  exception
    when unique_violation then
      raise notice 'PASS: duplicate like rejected';
  end;
end $$;

reset role;
reset request.jwt.claim.sub;

-- ---------------------------------------------------------------------------
-- Messaging: only thread members can read/write; no infinite recursion.
-- ---------------------------------------------------------------------------
do $$
declare v_thread_id uuid;
begin
  insert into public.direct_threads (user_a, user_b) values
    ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')
  returning id into v_thread_id;

  if (select count(*) from public.conversation_members where thread_id = v_thread_id) <> 2 then
    raise exception 'TEST FAILED: conversation_members should auto-populate to 2 rows on thread creation';
  end if;
  raise notice 'PASS: conversation_members auto-populated on thread creation';
end $$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('55555555-5555-5555-5555-555555555555', 'carol@example.com', '{"username":"carol","birth_date":"2000-01-01"}');

set role authenticated;
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';

do $$
declare v_count int;
begin
  select count(*) into v_count from public.direct_threads;
  if v_count <> 0 then
    raise exception 'TEST FAILED: a non-member should see zero threads, saw %', v_count;
  end if;
  raise notice 'PASS: non-member sees zero threads';
end $$;

reset role;
reset request.jwt.claim.sub;

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

do $$
declare v_count int;
begin
  select count(*) into v_count from public.direct_threads;
  if v_count <> 1 then
    raise exception 'TEST FAILED: thread member should see exactly 1 thread, saw %', v_count;
  end if;
  raise notice 'PASS: thread member sees their thread (no RLS recursion)';
end $$;

do $$
declare v_thread_id uuid; v_msg_id uuid;
begin
  select id into v_thread_id from public.direct_threads limit 1;
  insert into public.direct_messages (thread_id, sender_id, body)
  values (v_thread_id, '11111111-1111-1111-1111-111111111111', 'hi bob')
  returning id into v_msg_id;
  if v_msg_id is null then
    raise exception 'TEST FAILED: sending a message in your own thread should have succeeded';
  end if;
  raise notice 'PASS: sending a message in your own thread succeeds';
end $$;

reset role;
reset request.jwt.claim.sub;

-- ---------------------------------------------------------------------------
-- Notification fan-out
-- ---------------------------------------------------------------------------
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into public.follows (follower_id, following_id) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
reset role;
reset request.jwt.claim.sub;

do $$
declare v_count int;
begin
  select count(*) into v_count from public.notifications
  where recipient_id = '22222222-2222-2222-2222-222222222222' and type = 'follow';
  if v_count <> 1 then
    raise exception 'TEST FAILED: expected exactly 1 follow notification for bob, saw %', v_count;
  end if;
  raise notice 'PASS: follow notification created automatically';
end $$;

-- ---------------------------------------------------------------------------
-- Blocking side effects
-- ---------------------------------------------------------------------------
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into public.blocks (blocker_id, blocked_id) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
reset role;
reset request.jwt.claim.sub;

do $$
declare v_count int;
begin
  select count(*) into v_count from public.follows
  where follower_id = '11111111-1111-1111-1111-111111111111' and following_id = '22222222-2222-2222-2222-222222222222';
  if v_count <> 0 then
    raise exception 'TEST FAILED: blocking should remove an existing follow relationship';
  end if;
  raise notice 'PASS: blocking removes existing follow relationship';
end $$;

-- ---------------------------------------------------------------------------
-- Rate limiting
-- ---------------------------------------------------------------------------
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

do $$
declare i int; hit_limit boolean := false;
begin
  for i in 1..11 loop
    begin
      insert into public.posts (user_id, media_url, storage_path, media_type)
      values ('11111111-1111-1111-1111-111111111111', 'http://x/rl' || i || '.jpg', '11111111-1111-1111-1111-111111111111/rl' || i || '.jpg', 'image');
    exception
      when others then
        if sqlerrm ilike '%too often%' then
          hit_limit := true;
          exit;
        else
          raise;
        end if;
    end;
  end loop;
  if not hit_limit then
    raise exception 'TEST FAILED: posting rate limit (10 / 10 min) was never triggered after 11 attempts';
  end if;
  raise notice 'PASS: posting rate limit triggers after the configured threshold';
end $$;

reset role;
reset request.jwt.claim.sub;

do $$
begin
  raise notice 'TEXX SOCIAL RLS test suite: ALL TESTS PASSED';
end $$;
