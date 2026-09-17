# Security

## Threat model

The frontend is a fully public, unauthenticated-by-default client: the
Supabase URL and publishable key are visible to anyone who views source
(`public/js/config.js`). This is normal and safe **only if** every table
reachable through that key is correctly scoped by Row Level Security.
Before this repo, that guarantee was unverified (see
`docs/SITE_AUDIT.md` §6). This repo's migrations make it explicit and
testable.

## Row Level Security

Every table has RLS enabled (`supabase/migrations/0002_security_rls.sql`
onward) with `for select` / `for insert` / `for update` / `for delete`
policies scoped to `auth.uid()`. There is no table where a client can act
on another user's identity — every write policy checks the relevant
`*_id` column equals `auth.uid()`.

## IDOR prevention

Every mutating endpoint the frontend calls is a direct PostgREST table
operation, so "IDOR" reduces to "does RLS allow this row." Concretely:

- Deleting a post: RLS on `posts` requires `user_id = auth.uid()` — even
  though the client also filters `.eq('user_id', state.user.id)`, that
  client-side filter is defense in depth, not the actual control.
- Reading a DM thread: requires a matching row in `conversation_members`
  for the caller — a thread id alone is not enough.
- Updating a profile: `profiles` view's `instead of update` trigger updates
  `profiles_data where id = old.id`, and the base table's RLS additionally
  requires `id = auth.uid()`.

## Age verification (15+)

Enforced at the database layer, not just in JavaScript:

1. `handle_new_user()` trigger (`0003_age_verification.sql`) validates
   `birth_date` from signup metadata before creating a profile; raises an
   exception (aborting the whole signup transaction) if under 15.
2. A `check` constraint on `profiles_data.birth_date` makes it impossible
   to ever store a birth date under 15 via any path, including the
   post-login "confirm your birth date" update flow already in the client.

`birth_date` itself is never returned to anyone but its owner (see next
section) — the frontend never displays it publicly and, now, the database
won't serve it to anyone else either.

## PII protection (date of birth)

`public.profiles` is a view over `profiles_data` that replaces `birth_date`
with `null` for every row except the caller's own
(`case when id = auth.uid() then birth_date else null end`). This closes
the gap where a direct `select=birth_date` PostgREST call against another
user's row would otherwise succeed under a simple "select allowed for
everyone" policy (which is required for public profile browsing to work at
all).

## Upload safety

- MIME type and extension are never trusted from the client filename alone
  for the *bucket-level* limit: `storage.buckets.allowed_mime_types` on the
  `media` bucket (`0006_storage_media.sql`) is enforced by Supabase Storage
  itself against the actual upload `Content-Type`, independent of whatever
  the frontend claims.
- Storage keys are never client-chosen paths outside the uploader's own
  namespace: every storage policy requires
  `(storage.foldername(name))[1] = auth.uid()::text`.
- A hard 100 MB per-object ceiling exists at the bucket level regardless of
  what the composer UI's own (tighter) limits say.

## Rate limiting

`0005_rate_limiting.sql` adds `enforce_rate_limit()` plus `before insert`
triggers on `posts`, `comments`, `likes`, `follows`, `direct_messages`, and
`reports`. Limits are intentionally generous (not meant to make normal use
frustrating) but hard-stop scripted abuse:

| Action | Limit |
|---|---|
| Posts | 10 / 10 min |
| Comments | 30 / 5 min |
| Likes | 120 / 5 min |
| Follows | 60 / 10 min |
| Messages | 60 / 1 min |
| Reports | 20 / 1 hour |

This is enforced in the database, so it applies no matter what calls the
API — the browser client, a script, or a future mobile app.

## Roles

`profiles_data.role` is one of `user` / `moderator` / `admin`. No RLS
policy ever trusts a client-supplied role claim — every "is this a
moderator" check in a policy re-reads `profiles_data.role` for
`auth.uid()` at query time. There is no UI yet for granting roles (Phase 30
says not to overbuild admin tooling); granting a role today is a manual
`update public.profiles_data set role = 'moderator' where id = '...'` run
by whoever has direct database access, until an admin surface exists.

## Secrets

- **Public / safe to expose:** `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`
  (in `public/js/config.js`, committed) — these are designed to be public;
  every capability they grant is bounded by RLS.
- **Server-only, never in the browser bundle:** `SUPABASE_SERVICE_ROLE_KEY`
  — used only inside `supabase/functions/delete-account`, set as a Supabase
  Edge Function secret (`supabase secrets set`), never checked into this
  repo. See `.env.example`.

## Known residual risks (tracked, not silently ignored)

- **Live streaming has no TURN server configured** in the client code
  audited — viewers behind restrictive NATs may fail to connect. Not a
  data-security issue, but a reliability one; see `docs/SITE_AUDIT.md`.
- **Discover search is a client-side filter**, not a database full-text
  search — no injection risk (it's just `Array.filter`), but it means the
  full profile list for the search space is fetched to the client, which
  is a minor information-disclosure and performance concern at scale, not
  a fixed-yet item in this pass.
