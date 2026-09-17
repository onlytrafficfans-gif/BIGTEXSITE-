# API

There is no custom REST/RPC layer beyond Supabase's auto-generated
PostgREST API plus a small number of Postgres functions exposed as RPCs, and
one Edge Function. Every table access below is already gated by the RLS
policies in `supabase/migrations/0002_security_rls.sql` (and related
migrations) — this document describes the effective contract, not a
separate implementation.

## Auth (Supabase GoTrue, called via `supabase-js`)

| Action | Call | Notes |
|---|---|---|
| Sign up | `sb.auth.signUp({email, password, options:{data:{username, birth_date}}})` | Age + username validated server-side by `handle_new_user()` trigger; rejects the whole signup on failure |
| Log in | `sb.auth.signInWithPassword({email, password})` | |
| Log out | `sb.auth.signOut()` | |
| Forgot password | `sb.auth.resetPasswordForEmail(email, {redirectTo})` | |
| Session | `sb.auth.getSession()` / `sb.auth.onAuthStateChange(cb)` | |

## PostgREST tables (`sb.from('<table>')`)

All reads/writes go through RLS — see `docs/SECURITY.md` for the exact
policy per table. Summary of who can do what:

| Table | Read | Insert | Update | Delete |
|---|---|---|---|---|
| `profiles` (view) | everyone (own `birth_date` only) | self | self | — |
| `posts` | published + active-account + not blocked | self | self | self |
| `media` | via parent post visibility, or owner | owner | owner | owner |
| `follows` | everyone | self as follower, not if blocked | — | self as follower |
| `likes` | everyone | self | — | self |
| `comments` | published | self | self, or post owner, or moderator | self, post owner, or moderator |
| `saved_posts` | self | self | — | self |
| `direct_threads` | member only | member, not if blocked | — | — |
| `direct_messages` | thread member only | thread member | — | — |
| `live_sessions` | everyone | self as host | self as host | — |
| `blocks` | self (as blocker) | self | — | self |
| `reports` | reporter, or moderator/admin | reporter | moderator/admin only | — |
| `notifications` | self (as recipient) | — (trigger only) | self (mark read) | — |

## RPCs (Postgres functions, `sb.rpc('<name>')`)

| Function | Purpose | Auth |
|---|---|---|
| `mark_all_notifications_read()` | Marks every unread notification for the caller as read | authenticated |
| `deactivate_my_account()` | Sets `account_status = 'deactivated'` for the caller | authenticated |
| `reactivate_my_account()` | Reverses deactivation | authenticated |
| `enforce_rate_limit(action, max_count, window)` | Internal — called by triggers, not meant to be invoked directly from the client | authenticated |

## Storage (`sb.storage.from('media')`)

| Action | Path convention | Policy |
|---|---|---|
| Upload | `${auth.uid()}/<timestamp>-<uuid>.<ext>` | Insert only under your own uid prefix |
| Upload cover | `${auth.uid()}/covers/<timestamp>-<uuid>.<ext>` | Same as above |
| Read | any object in bucket `media` | Public (bucket is public — feed images/videos are rendered directly from `getPublicUrl()`) |
| Delete | any object under your own uid prefix | Owner only |

Bucket-level limits (`0006_storage_media.sql`): 100 MB hard ceiling per
object, MIME allow-list (`image/jpeg`, `image/png`, `image/webp`,
`video/mp4`, `video/quicktime`, `video/webm`). The frontend additionally
enforces its own, tighter limits before upload (15 MB images / 100 MB
video / 10 MB covers) — those are UX guardrails only; the bucket limit above
is the real backstop.

## Edge Functions

### `POST /functions/v1/delete-account`

Permanently deletes the caller's account. Requires a valid `Authorization:
Bearer <access_token>` header (no body). Resolves the caller's identity
from that token server-side — a user can never delete another account by
supplying a different id, because no id is ever accepted from the request.

```json
// 200
{ "ok": true }

// 401
{ "error": { "code": "UNAUTHENTICATED", "message": "Invalid session." } }

// 500
{ "error": { "code": "DELETE_FAILED", "message": "Could not delete account. Please try again." } }
```

## Error shape

Postgres/PostgREST errors surface to the client as `{ message, code,
details, hint }` (Supabase's standard shape) and the frontend already
displays `error.message` via `toast()`. Rate-limit and validation errors
raised from triggers (`raise exception '...'`) appear the same way, so no
frontend change was needed to surface any of the new server-side checks
added in this repo.
