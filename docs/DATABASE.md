# Database

Postgres, managed by Supabase. All schema lives in `supabase/migrations/`,
applied in filename order. Every migration is idempotent (`if not exists`,
`create or replace`, `drop ... if exists` before `create`) so re-running the
full set against an already-migrated database is safe.

## Migration order

| File | Purpose |
|---|---|
| `0001_init_schema.sql` | All tables, constraints, indexes |
| `0002_security_rls.sql` | RLS on every table; `profiles` DOB-masking view |
| `0003_age_verification.sql` | Server-side 15+ enforcement |
| `0004_notifications_blocking.sql` | Notification fan-out triggers, block side-effects |
| `0005_rate_limiting.sql` | Generic rate-limit function + per-table triggers |
| `0006_storage_media.sql` | `media` storage bucket + owner-scoped policies |
| `0007_account_lifecycle.sql` | Deactivate/reactivate RPCs |

## Entity overview

```
profiles_data ──┬── posts ──┬── likes
 (birth_date,   │           ├── comments
  role, status) │           └── media (normalized, future multi-asset)
                ├── follows (self-referencing)
                ├── blocks (self-referencing)
                ├── saved_posts ── posts
                ├── direct_threads ── conversation_members
                │        └── direct_messages
                ├── live_sessions
                ├── reports ── posts / comments / profiles_data
                └── notifications
```

`public.profiles` is a **view**, not a table — see `0002_security_rls.sql`.
The real table is `profiles_data`; PostgREST clients (including the live
frontend) keep calling `.from('profiles')` unmodified.

## Key constraints

- `profiles_data.username` — unique (case-insensitive), 3–24 chars,
  `[A-Za-z0-9_]` only.
- `profiles_data.birth_date` — must represent an age ≥ 15 at write time.
- `follows` / `blocks` — composite primary key prevents duplicates; a
  `check` constraint prevents self-follow / self-block.
- `likes` — composite primary key `(post_id, user_id)` prevents duplicate
  likes at the database level (no application-level "already liked" race).
- `direct_threads` — unique index on `(user_a, user_b)` with `user_a <
  user_b` enforced, so there is exactly one thread per pair regardless of
  who started it.
- `posts.status`, `comments.status`, `reports.status`,
  `profiles_data.account_status` — moderation/lifecycle state machines
  (see `docs/SECURITY.md` for the values and who can set them).

## Indexes

Every foreign key used in a hot-path query has a matching index:
`posts(user_id, created_at desc)`, `posts(created_at desc)` for the feed,
`likes(post_id)`, `comments(post_id, created_at)`,
`follows(following_id)`/`follows(follower_id)`,
`direct_messages(thread_id, created_at)`,
`notifications(recipient_id, created_at desc) where read_at is null` for
fast unread-count queries, `rate_limit_events(user_id, action, created_at
desc)`.

## Running migrations

```bash
# Local dev stack (Docker required)
supabase start
supabase db reset        # applies migrations/ + seed.sql fresh

# Against a real project (after §6 of docs/SITE_AUDIT.md is satisfied)
supabase link --project-ref <project-ref>
supabase db push
```

## Non-destructive by design

No migration in this repo contains `drop table`, `truncate`, or an
unguarded `alter column type`. The one structural change — `profiles` →
`profiles_data` + a view named `profiles` — is a rename plus a view, which
preserves every existing row; it is wrapped in a guard that only runs if
`profiles` currently exists as an ordinary table (so it's a no-op if this
migration has already been applied, and never targets an object that isn't
what it expects).
