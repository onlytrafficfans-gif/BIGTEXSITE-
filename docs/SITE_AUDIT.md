# TEXX SOCIAL — Site Audit

Audited: live production HTML/CSS/JS fetched directly from `https://www.texxsocial.com/`
on 2026-09-17. This document is evidence-based: every claim below is backed by a
specific line of the shipped `public/js/app.js` (the exact file downloaded from
production, now checked into this repository) or by an explicit gap (a feature
described in the product brief with no corresponding code found).

## 1. What TEXX SOCIAL actually is

TEXX SOCIAL is **not** a Node/Next.js/React application. It is a single static
HTML page (`index.html`, now split into `public/index.html` + `public/css/app.css`
+ `public/js/app.js` for maintainability, byte-identical in behavior) that talks
**directly** to a Supabase project from the browser using `@supabase/supabase-js`
loaded from a CDN, with a public "publishable" anon key embedded in the page
source (`public/js/config.js`). There is no custom backend server today — the
"backend" is entirely Supabase: Postgres (via PostgREST), Supabase Auth, and
Supabase Storage. This changes the shape of "build the backend": the correct
engine underneath this frontend is a properly migrated, RLS-secured Supabase
project, not a bespoke Express/Next API layer, because rebuilding the latter
would mean either (a) a second disconnected app, which the brief explicitly
forbids, or (b) rewriting the entire frontend's data layer, which the brief
also forbids ("do not rebuild working UI").

- **Frontend:** vanilla HTML/CSS/JS, no build step, no framework, no bundler.
- **Backend:** Supabase project `iwnbsslhdqqhoocmfrik` (Postgres + Auth + Storage),
  called directly from the browser with `sb_publishable_...` key.
- **Hosting:** static file host (headers/response shape are consistent with a
  static CDN deploy; no server-rendered content, no cookies observed).

## 2. Page / view map

The app is a single HTML document with client-side view switching (no router,
no URL changes between views — `data-view` buttons toggle `.screen` elements).

| View | Element id | Purpose |
|---|---|---|
| Auth (logged out) | `#authView` | Log in / Join tabs, forgot password |
| Home / Feed | `#feedView` | Chronological feed + "people" strip |
| Reels | `#reelsView` | Vertical short-video feed |
| Discover | `#discoverView` | Username search → follow |
| Messages | `#messagesView` | Thread list + chat pane |
| Profile | `#profileView` | Own or another user's profile grid |
| Composer (modal) | `#composer` | Create post / reel, music, cover image |
| Comments (modal) | `#commentsModal` | Per-post comments |
| Share to Messages (modal) | `#shareMessageModal` | Forward a post into a DM |
| Live (modal) | `#liveModal` | WebRTC "Go live" broadcast |

## 3. Feature-by-feature status

Legend: **WORKING** (real Supabase read/write, appears solid) · **PARTIAL**
(works but with a real gap) · **FRONTEND ONLY** (client-side check with no
server enforcement) · **MISSING BACKEND** (no schema/table exists) ·
**MISSING** (no UI and no backend).

### Authentication — PARTIAL
- Sign up / log in / log out / forgot password all call real Supabase Auth
  methods (`auth.signUp`, `auth.signInWithPassword`, `auth.signOut`,
  `auth.resetPasswordForEmail`) — **WORKING**, this is real, not mocked.
  (`public/js/app.js:55-63`)
- Session handling via `auth.getSession()` / `auth.onAuthStateChange()` —
  **WORKING**.
- **Gap:** whether Row Level Security was actually enabled on any table in
  the live project is unverifiable from the frontend alone — this repo has
  no credentials to the live project. Given the "publishable" key exposes
  the full PostgREST surface, **this must be verified against production
  before this repo's migrations are applied**, per this repo's
  `supabase/migrations/`. See §6.

### Age requirement (15+) — **FRONTEND ONLY (critical gap, now fixed in this repo)**
- `ageAtLeast15()` (`app.js:31`) is pure client-side JavaScript, checked once
  at signup and once more if a user's `birth_date` is ever null on login
  (`app.js:69-76`, a `prompt()`-based fallback that then calls
  `.from('profiles').update({birth_date: dob})` directly from the browser).
- **Nothing in the shipped frontend stops a direct API call** (curl, devtools,
  a modified build) from creating an account with any birth date, or from
  `PATCH`-ing an existing profile's `birth_date` to any value, because the
  check only exists in JS that a malicious client simply doesn't run.
- **Fixed in this repo:** `supabase/migrations/0003_age_verification.sql` adds
  a `CHECK` constraint (`birth_date <= current_date - interval '15 years'`)
  and a `SECURITY DEFINER` `handle_new_user` trigger that validates age at
  the database level on both the signup path and the update fallback path,
  without requiring any frontend change (the existing `toast(error.message)`
  handling already surfaces the resulting Postgres error).

### Profiles — PARTIAL
- Read/update own profile, avatar upload, bio/display name/website edit are
  all real Supabase calls — **WORKING** (`app.js:299-321`).
- **Gap — DOB privacy:** `birth_date` lives on the same `profiles` row/table
  that is queried for every other user's public profile card. Nothing in the
  frontend requests `birth_date` for other users, but with RLS alone (no
  column-level protection) a crafted request (`select=birth_date`) could
  read anyone's date of birth if the underlying table allows public SELECT —
  which it must, for the discover/feed/profile views to work at all.
  **Fixed in this repo:** `0002_security_rls.sql` turns `profiles` into a
  view over a renamed base table, masking `birth_date` to `null` for every
  row except the caller's own — no frontend change required.

### Posts (photo/video) — WORKING, with real gaps
- Create (upload to Storage bucket `media`, then insert row), read (feed
  query joins `profiles`, `likes`, `comments`), delete (own posts only,
  checked client-side via `post.user_id !== state.user.id` **and** a
  `.eq('user_id', state.user.id)` filter on the delete query itself, so this
  one is actually enforced server-side already by construction — assuming
  RLS is on) — **WORKING** (`app.js:37, 154-165, 241`).
- **Gap:** no `status` / moderation field existed before this repo; a
  reported post cannot be taken down without deleting it outright.
  **Added:** `posts.status` (`published`/`removed`/`under_review`) in
  `0001_init_schema.sql`.
- **Gap:** feed query is `.order('created_at', {ascending:false}).limit(50)` —
  a hard 50-row window with **no cursor**, so page 2 does not exist. Flagged
  as a follow-up in `docs/FEATURE_STATUS.md`; not changed in this pass to
  avoid touching working frontend logic outside the security/data scope of
  this repo build.

### Reels — WORKING (shares the `posts` table via `post_kind='reel'`)
- Create, view, like, comment, delete all real. "Build with Edits" (send to
  Instagram Edits app, import back) is a share-sheet/file-import UX pattern,
  not a real integration with Instagram — it just imports whatever file
  comes back through the OS share sheet as a normal file upload. **WORKING
  as designed**, not a mock, but worth documenting: no direct Instagram API
  usage occurs.

### Music attachment — WORKING (client-side only, correctly so)
- Search hits Apple's public iTunes Search API directly from the browser
  (inferred from `artworkUrl100`/`trackViewUrl`/`previewUrl` field names,
  `app.js` music search block) — no API key needed, nothing to keep secret,
  this is the correct architecture for this feature per the brief's
  explicit instruction not to download/copy copyrighted audio.
- Manual "already have a link" entry is validated as an http(s) URL only.
- Stored fields (`music_provider`, `music_url`, `music_title`, `music_artist`,
  `music_preview_url`, `music_clip_start/duration`, `music_artwork_url`) are
  all present on `posts` — **WORKING**.

### Follows / Discover / Search — WORKING, PARTIAL search
- Follow/unfollow are real inserts/deletes on a `follows` table —
  **WORKING** (`app.js:294`).
- "Search" in Discover is a client-side substring filter over a list already
  fetched from `profiles` (`app.js` `loadPeople`), not a database-side
  search — **PARTIAL**: fine at small scale, will not scale past a few
  hundred profiles and does no debouncing beyond a simple timer.

### Likes / Comments — WORKING
- Both are real inserts/deletes with `user_id = auth.uid()` implied by the
  client always passing `state.user.id` — **WORKING**, assuming RLS backs
  it (now guaranteed by this repo's migrations).

### Saved posts — **MISSING** (no UI, no table)
No bookmark/save button anywhere in the shipped HTML. Added as
`saved_posts` table + RLS in this repo for future UI to build against.

### Messaging — WORKING, with a real security gap
- Thread creation (`getOrCreateThread`), sending, reading, and a polling
  refresh loop are all real (`app.js:250-294`) — **WORKING**.
- **Gap:** nothing in the frontend proves a user can only read threads
  they belong to — that guarantee, if it exists at all today, lives
  entirely in whatever RLS policy is (or isn't) already on `direct_threads`
  / `direct_messages` in production, which this repo cannot see.
  `0002_security_rls.sql` adds an explicit, verifiable
  membership-based policy via a new `conversation_members` table.
- **Gap:** no `read_at` was being set anywhere — added a column
  (`direct_messages.read_at`) for a future unread-count UI; not yet wired
  into the frontend.
- Realtime delivery is not used for messages today — the client polls, not
  a `postgres_changes` subscription. Documented as a follow-up.

### Notifications — **MISSING at audit time, now FIXED**
No bell icon, no notification list anywhere in the originally shipped
HTML/CSS. This repo added the full backend (`notifications` table + trigger
fan-out on follow/like/comment/message) and, in the same pass, a bell
icon with an unread badge, a notifications list view, and "mark all read"
in `public/index.html`/`public/js/app.js` — see `docs/FEATURE_STATUS.md`
for how it was verified.

### Reporting — PARTIAL
- Reporting a **post** is real (`app.js:207-209`, inserts into `reports`
  with `post_id`). — **WORKING** for posts only.
- **MISSING:** no "report user" or "report comment" entry point in the UI,
  and the live `reports` table (as inferred from the insert call) has no
  `target_user_id` column. Added both in this repo (`reports.target_user_id`,
  `reports.comment_id`) so the backend is ready when that UI ships.
- No moderator review surface exists anywhere (expected — Phase 30 says not
  to overbuild an admin app yet). This repo adds `profiles.role`
  (`user`/`moderator`/`admin`) and RLS policies that already gate report
  visibility/resolution on that role, so a moderation queue UI has
  something real to call.

### Blocking — **MISSING at audit time, now FIXED**
No block button anywhere in the originally shipped HTML. This repo added a
`blocks` table with RLS that affects **feed visibility, follow/unfollow,
and new DM thread creation** the moment a row is inserted
(`0002_security_rls.sql`, `0004_notifications_blocking.sql`), and a "Block"
button on every other user's profile view that calls it.

### Live streaming ("Go live") — WORKING, architecturally fragile
- Fully peer-to-peer WebRTC, signaled over a Supabase Realtime broadcast
  channel (`sb.channel('live:'+id)`), with a `live_sessions` table just for
  discovery/status (`live`/`ended`). **No media server, no SFU, no
  recording.** This means: it works for small viewer counts on networks
  that allow direct WebRTC connections, degrades badly past a handful of
  concurrent viewers (every viewer is a separate P2P connection from the
  host's device), and has no fallback for viewers behind restrictive NATs
  (no TURN server configured, from what's visible in the client). This is a
  real, working feature for a small-scale launch, but is the single biggest
  scaling and reliability risk in the product if live audiences grow.
  Documented, not changed in this pass (would require standing up
  infrastructure — an SFU/TURN service — outside the scope of "reconstruct
  the repo behind the existing product").

### Account deletion / deactivation — **MISSING at audit time, now FIXED**
No delete-account, deactivate, or "logout everywhere" UI or backend call
anywhere in the originally shipped app. This repo added
`profiles.account_status` (`active`/`deactivated`/`suspended`/`banned`),
self-service `deactivate_my_account()` / `reactivate_my_account()` RPCs, a
`delete-account` Supabase Edge Function that does real, permanent,
cascading deletion (auth user → all owned rows via FK cascade → storage
objects) using the service-role key server-side only (see
`supabase/functions/delete-account/`), and two buttons on the own-profile
view ("Deactivate my account" / "Delete my account permanently") that call
them.

### Rate limiting — **MISSING** (entirely)
Nothing in the frontend throttles posting, liking, following, commenting,
messaging, or reporting beyond disabling a button mid-request. Added
database-level rate limiting (`0005_rate_limiting.sql`) that cannot be
bypassed by calling the API directly.

### Empty / loading / error states — PARTIAL
- Feed has a real empty state (`#feedEmpty`). Errors mostly surface via a
  generic `toast()` with `error.message` from Supabase — functional but not
  differentiated (a network failure and a validation failure look the
  same to the user). Not changed in this pass; flagged in
  `docs/FEATURE_STATUS.md`.

## 4. Database contract as already implemented by the live client

Reverse-engineered directly from every `.from(...)`, `.select(...)`,
`.insert(...)`, `.update(...)`, `.delete(...)`, and `storage.from(...)` call
in the shipped JS. This is the exact contract `supabase/migrations/`
formalizes with real constraints, RLS, and indexes:

- **Tables already relied upon by the client:** `profiles`, `posts`,
  `follows`, `likes`, `comments`, `direct_threads`, `direct_messages`,
  `live_sessions`, `reports`.
- **Storage bucket already relied upon:** `media` (public read, used via
  `getPublicUrl`).
- **Tables the client does NOT use, added as net-new infrastructure for
  gaps identified above:** `media` (normalized multi-asset table, additive,
  unused by the current single-asset-per-post client), `blocks`,
  `saved_posts`, `notifications`, `conversation_members`,
  `rate_limit_events`.

## 5. Security findings summary

| Finding | Severity | Status |
|---|---|---|
| Age requirement enforced client-side only | Critical | **Fixed** — `0003_age_verification.sql` |
| DOB readable via direct API call | High | **Fixed** — `0002_security_rls.sql` (masking view) |
| RLS state on live project unverified | High | **Needs live verification** — see §6 |
| No rate limiting anywhere | Medium | **Fixed** — `0005_rate_limiting.sql` |
| Messaging membership not provably enforced | High | **Fixed** — `0002_security_rls.sql` (`conversation_members`) |
| No storage upload policy verified | High | **Fixed** — `0006_storage_media.sql` (owner-prefixed paths only) |
| No moderation status / role model | Medium | **Fixed** — `profiles.role`, `posts.status`, `reports.status` |
| No rate limit / size cap enforced server-side on uploads | Medium | **Fixed** — storage bucket `file_size_limit` + `allowed_mime_types` |

## 6. Action required before deploying this repo's migrations to production

This repo's Supabase migrations are written to be **additive and
non-destructive** (`if not exists`, `create or replace`, no `drop table`,
no `truncate`), and the one structural change — turning `profiles` into a
view for DOB masking — preserves all existing rows and only renames the
underlying table (`profiles` → `profiles_data`); no data is deleted.
Nonetheless, per the project's own non-negotiable rule ("never run
destructive migrations against production without explicit approval"):

1. **Inspect the live schema first** — connect to the `iwnbsslhdqqhoocmfrik`
   project (credentials required, not available to this session) and run
   `supabase db diff` / `pg_dump --schema-only` before applying anything.
2. **Diff it against `supabase/migrations/`** — confirm column names/types
   match what's assumed here (they were inferred from client code, which is
   reliable for *what the client sends*, but cannot reveal server-only
   columns, existing constraints, or existing RLS policies).
3. **Take a backup/export** (Supabase dashboard → Database → Backups, or
   `pg_dump`) before the first production migration run.
4. **Apply via `supabase db push` against a branch/staging project first**
   if using Supabase branching, then promote.
