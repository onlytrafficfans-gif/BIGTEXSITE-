# TEXX SOCIAL

Share your moments. Build your circle.

TEXX SOCIAL is a social app: photo/video posts, Reels, a following-based
feed, Discover search, 1:1 messaging, streaming-music attachments on posts,
and peer-to-peer live broadcasting. This repository is the reconstructed,
production-quality engine behind the live product at
[texxsocial.com](https://www.texxsocial.com/) — see `docs/SITE_AUDIT.md`
for exactly what was audited and fixed, and `docs/FEATURE_STATUS.md` for a
full feature-by-feature status table.

## Architecture in one paragraph

The frontend (`public/`) is a static, build-step-free HTML/CSS/JS app that
talks directly to [Supabase](https://supabase.com) — Postgres, Auth, and
Storage — from the browser. There is no separate application server; the
"backend" in this repo is a fully migrated, Row-Level-Security-secured
Supabase schema (`supabase/migrations/`) plus one Edge Function for the one
operation that genuinely needs a service-role key (account deletion). See
`docs/ARCHITECTURE.md` for the full picture and rationale.

## Repository structure

```
public/            Static frontend (deploy as-is, no build step)
supabase/          Database migrations, Edge Functions, local dev config
docs/              Architecture, database, API, security, deployment, audit docs
tests/             RLS + smoke tests, run against a local Supabase stack
.github/workflows/ CI (lint, typecheck, tests)
```

## Local setup

Prerequisites: [Supabase CLI](https://supabase.com/docs/guides/cli),
Docker (for the local Supabase stack), Deno (for Edge Function checks),
Node.js 18+ (only used to run a static file server for local frontend dev).

```bash
# 1. Install the Supabase CLI if you don't have it
npm install -g supabase

# 2. Start the local Supabase stack (Postgres + Auth + Storage + Studio)
supabase start

# 3. Apply migrations + seed
supabase db reset

# 4. Serve the frontend locally
npm run dev
# → http://localhost:3000
```

By default `public/js/config.js` points at the **live production** Supabase
project (`iwnbsslhdqqhoocmfrik`) — that's what makes the site work
unmodified today. For local development against your own local Supabase
stack instead, edit `public/js/config.js` to point at the URL/anon key
printed by `supabase start` (do not commit that change on a branch that
deploys to production).

## Environment variables

See `.env.example`. The frontend needs no build-time environment variables
(its Supabase URL/key are public and live directly in
`public/js/config.js`, by design — see `docs/SECURITY.md`). Server-only
secrets (`SUPABASE_SERVICE_ROLE_KEY`) are used exclusively by
`supabase/functions/delete-account` and must be set via
`supabase secrets set`, never in a `.env` file that ships to the browser.

## Database

All schema changes are migrations in `supabase/migrations/`, applied in
order, idempotent, and non-destructive. See `docs/DATABASE.md` for the full
entity model and `docs/SITE_AUDIT.md` §6 for the steps required before
applying these against the existing production database.

```bash
supabase db reset          # fresh local database from migrations + seed
supabase link --project-ref <ref> && supabase db push   # apply to a real project
```

## Development

```bash
npm run dev          # serve public/ locally on :3000
npm run lint          # lint SQL migrations
npm run typecheck      # typecheck the Edge Function (Deno)
```

## Testing

```bash
npm test              # runs tests/ against the local Supabase stack (supabase start required)
```

`tests/rls.test.sql` asserts the Row Level Security behavior described in
`docs/SECURITY.md` — e.g. a user cannot read another user's `birth_date`,
cannot read a DM thread they're not a member of, cannot delete another
user's post.

## Production build

There is no build step for the frontend — `public/` is deployed as-is.
See `docs/DEPLOYMENT.md` for the full deployment process (frontend host +
Supabase migrations + Edge Functions).

## Troubleshooting

- **"TEXX SOCIAL is still connecting"** — the Supabase client failed to
  initialize; check that `public/js/config.js` has a valid URL/key and that
  `https://cdn.jsdelivr.net` is reachable.
- **Signup rejected with an age-related message** — this is the new
  server-side age check (`docs/SECURITY.md`) working as intended, not a
  bug.
- **RLS "permission denied" on a query that used to work** — check
  `docs/API.md`'s table for who's allowed to do what; if a legitimate use
  case is blocked, add a migration adjusting the policy rather than
  disabling RLS.

## Security considerations

See `docs/SECURITY.md` for the full write-up: Row Level Security on every
table, server-side age verification, DOB masked from non-owners, owner-
scoped storage paths, database-level rate limiting, and secret handling.
