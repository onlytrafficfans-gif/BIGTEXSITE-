# Architecture

## Overview

TEXX SOCIAL is a static, framework-free frontend (`public/`) that talks
directly to a Supabase project (Postgres + Auth + Storage + Realtime) using
the browser-side `@supabase/supabase-js` client. There is no custom
application server in this stack — Supabase's PostgREST layer, guarded by
Postgres Row Level Security, **is** the API.

```
┌─────────────────────────┐        ┌──────────────────────────────────────┐
│        Browser           │        │              Supabase                │
│                          │        │                                      │
│  public/index.html       │  REST  │  PostgREST  ──►  Postgres            │
│  public/css/app.css      │◄──────►│               (RLS-enforced tables,  │
│  public/js/config.js     │        │                triggers, functions)  │
│  public/js/app.js        │  Auth  │  GoTrue (Supabase Auth)              │
│  (no build step)         │◄──────►│                                      │
│                          │ Storage│  Storage (bucket: media)             │
│                          │◄──────►│                                      │
│                          │Functions│  Edge Functions (Deno)              │
│                          │◄──────►│  - delete-account                    │
└─────────────────────────┘        └──────────────────────────────────────┘
```

## Why not a custom Node/Express backend?

The live product already ships this way, with real user accounts and data
behind it. Introducing a separate server would mean either:

1. A second, disconnected application that duplicates Supabase's job
   (explicitly forbidden by the project brief), or
2. Rewriting `public/js/app.js`'s entire data layer to call new endpoints
   instead of Supabase directly (a full frontend rewrite, which the brief
   also forbids — "do not rebuild working UI").

Instead, this repo's "backend reconstruction" is: formalize the schema the
frontend already assumes, turn on and correctly scope Row Level Security,
add the server-side checks that must never live in the browser (age
verification, rate limiting), and add the tables/functions for features the
UI doesn't have yet (notifications, blocking, saved posts, account
deletion) so a future UI change has a real API to call on day one.

Where genuine server-only logic is unavoidable — permanently deleting an
account, which requires the Supabase service-role key — it lives in a
Supabase Edge Function (`supabase/functions/delete-account`), never in the
browser.

## Repository layout

```
public/                  Static frontend — deployed as-is (no build step)
  index.html
  css/app.css
  js/config.js            Public Supabase URL + publishable key (safe to expose)
  js/app.js                All application logic (auth, feed, reels, messaging, live, music)
  assets/                  Brand images extracted from the production page

supabase/
  config.toml              Local dev stack config (supabase start)
  migrations/               Ordered, idempotent SQL — the real "backend"
  functions/                 Edge Functions (service-role-only operations)
  seed.sql                  Local dev seed template (never applied to prod)

docs/                     This documentation set
tests/                    Automated tests (Postgres RLS + smoke tests)
.github/workflows/        CI: lint, typecheck (Deno functions), SQL tests
```

## Data flow examples

**Creating a post:** browser uploads the file straight to Supabase Storage
(`storage.from('media').upload(...)`, owner-prefixed path enforced by a
storage policy in `0006_storage_media.sql`), gets back a public URL, then
inserts a row into `posts` (RLS requires `user_id = auth.uid()`). No file
ever passes through an application server.

**Age verification:** enforced twice, both server-side now — once by a
`SECURITY DEFINER` trigger on `auth.users` insert (rejects the whole signup
transaction if under 15), and once by a `CHECK` constraint on
`profiles_data.birth_date` that also covers the post-login "confirm your
birth date" update path already in the client.

**Notifications:** never inserted directly by the client (RLS on
`notifications` has no client-facing INSERT policy). They're fan-out by
`SECURITY DEFINER` triggers on `follows`, `likes`, `comments`, and
`direct_messages` inserts, so they can't be forged.

## Extending this later without a rebuild

- **Feed ranking:** today's query is deterministic (most recent 50 posts).
  To add a real ranking algorithm, replace the single `.order()` call in
  `loadFeed()` with a call to a new Postgres function/RPC — the rest of the
  rendering code doesn't need to change.
- **Realtime messaging:** `direct_messages` already has RLS scoped to
  `conversation_members`; swapping the client's polling loop for a
  `sb.channel(...).on('postgres_changes', ...)` subscription is a frontend
  change only.
- **Notifications UI:** the backend (table + triggers + RLS + `mark_all_
  notifications_read()` RPC) is complete; only a bell icon + list view need
  to be added to `public/js/app.js`.
