# Deployment

## Frontend (`public/`)

The frontend is a static site with zero build step — `public/` can be
deployed as-is to any static host (Vercel, Netlify, Cloudflare Pages,
GitHub Pages, S3+CloudFront, etc.). The production deployment this repo
targets is whatever already serves `https://www.texxsocial.com/` today —
preserve that host/provider unless there's a concrete reason to migrate;
this repo does not change hosting.

Deploy steps (host-agnostic):
1. Set the static site's publish directory to `public/`.
2. No environment variables are required for the frontend at build time —
   `public/js/config.js` already contains the public Supabase URL/key. If
   you want a separate staging Supabase project, edit that file's values
   for the staging deploy only (never commit staging-only edits back to the
   branch that deploys to production).
3. No build command needed (static files only).

## Backend (Supabase)

The backend is the Supabase project itself — there's no separate server to
provision. Two things are deployed independently:

### 1. Database migrations

```bash
supabase link --project-ref <your-project-ref>
supabase db push
```

Read `docs/SITE_AUDIT.md` §6 before running this against the existing
production project — inspect the live schema and take a backup first, even
though every migration here is additive/non-destructive.

### 2. Edge Functions

```bash
supabase functions deploy delete-account
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=<value> SUPABASE_URL=<value>
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` must be set as **function
secrets** (`supabase secrets set`), never as frontend environment
variables and never committed to this repo.

## Media persistence

All user uploads live in Supabase Storage (bucket `media`), which is
durable, provider-managed object storage — not the application filesystem.
Nothing in this stack writes user data to an ephemeral server disk, so
redeploying the frontend (a static file swap) or the Edge Functions never
risks losing uploads. Database data lives in Supabase's managed Postgres,
independent of any deploy.

## CI/CD

`.github/workflows/ci.yml` runs on every push/PR:
- Lints the SQL migrations for syntax errors (`supabase db lint` style
  check via a local Postgres container).
- Validates the Edge Function TypeScript with `deno check`.
- Runs the RLS smoke tests in `tests/`.

Deployment itself (the `supabase db push` / `functions deploy` /
static-host deploy) is intentionally **not** automated in this repo's CI —
those require production credentials that must live in the hosting
provider's own secret store, set up by whoever owns those accounts, not
committed here.

## Rollback

- **Frontend:** redeploy the previous static build (most hosts keep
  deploy history natively).
- **Database:** every migration is additive; there is no destructive
  change to roll back. If a specific migration needs reverting, write a
  new migration that undoes it explicitly rather than deleting/rewriting
  history — this preserves the audit trail Supabase's migration system
  depends on.
