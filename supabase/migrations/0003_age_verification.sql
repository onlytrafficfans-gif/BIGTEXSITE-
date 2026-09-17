-- 0003_age_verification.sql
-- Server-side enforcement of the "TEXX SOCIAL is for ages 15+" rule (Phase 5).
--
-- Before this migration, ageAtLeast15() in public/js/app.js was the ONLY
-- place age was checked -- pure client-side JavaScript, trivially bypassed
-- with devtools or a direct REST/curl call to
-- POST /auth/v1/signup or PATCH /rest/v1/profiles?id=eq.<uuid>.
-- This migration makes the database itself refuse to store an underage
-- birth_date, on both the initial signup path and the post-login "confirm
-- your birth date" fallback path in loadProfile().

-- A hard floor: no row in profiles_data may ever hold a birth_date that
-- represents an age under 15, at insert OR update time.
alter table public.profiles_data
  drop constraint if exists profiles_data_min_age_check;
alter table public.profiles_data
  add constraint profiles_data_min_age_check
  check (birth_date is null or birth_date <= (current_date - interval '15 years'));

-- handle_new_user: creates the profiles_data row from the signUp() metadata
-- {username, birth_date} that public/js/app.js already sends today. Runs as
-- SECURITY DEFINER inside the same transaction as the auth.users insert, so
-- raising an exception here rolls back the entire signup -- the Supabase
-- Auth API surfaces that as an error to the client's signUp() call, which
-- public/js/app.js already displays via toast(error.message). No frontend
-- change is required for this protection to take effect.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text;
  v_birth_date date;
begin
  v_username := trim(new.raw_user_meta_data ->> 'username');
  if v_username is null or v_username = '' then
    raise exception 'A username is required.';
  end if;
  if v_username !~ '^[A-Za-z0-9_]{3,24}$' then
    raise exception 'Username must be 3-24 letters, numbers, or underscores.';
  end if;

  if new.raw_user_meta_data ? 'birth_date' and (new.raw_user_meta_data ->> 'birth_date') <> '' then
    v_birth_date := (new.raw_user_meta_data ->> 'birth_date')::date;
    if v_birth_date > (current_date - interval '15 years') then
      raise exception 'You must be at least 15 years old to join TEXX SOCIAL.';
    end if;
  else
    v_birth_date := null;
  end if;

  insert into public.profiles_data (id, username, birth_date)
  values (new.id, v_username, v_birth_date);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
