# Zionxyos v0.3.0 — Vercel Deployment Guide

Use this guide for the first production deployment. A Vercel deployment should happen only after the Supabase migration and a real local/CI `npm run preflight` succeed.

## 1. Supabase preparation

For an existing v0.2 database, apply `supabase/migrations/003_production_release.sql` once. For a clean project, apply 001 -> 002 -> 003 in order.

After the migration, verify that:

- the intended operator is the only `sysadmin`;
- the `zionxyos-media` Storage bucket exists and is public;
- RLS is enabled on the new v0.3 tables;
- `/api/health` can read the `site_name` setting;
- the sysadmin can complete TOTP MFA and receive an AAL2 session.

## 2. Vercel environment variables

Configure these for Production and the environments you actually use:

```env
NEXT_PUBLIC_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_REPLACE_ME
NEXT_PUBLIC_SITE_URL=https://YOUR_DOMAIN
RATE_LIMIT_SALT=LONG_RANDOM_SECRET
```

Optional sysadmin update controls:

```env
VERCEL_DEPLOY_HOOK_URL=https://api.vercel.com/v1/integrations/deploy/...
ZIONXYOS_RELEASE_MANIFEST_ALLOWED_HOSTS=raw.githubusercontent.com
ZIONXYOS_UPDATE_WEBHOOK_TOKEN=OPTIONAL_RELEASE_MANIFEST_TOKEN
```

`VERCEL_DEPLOY_HOOK_URL`, `ZIONXYOS_UPDATE_WEBHOOK_TOKEN`, and `RATE_LIMIT_SALT` are server-only secrets. `ZIONXYOS_RELEASE_MANIFEST_ALLOWED_HOSTS` is a server-only comma-separated hostname allowlist (not a secret). Never rename them with a `NEXT_PUBLIC_` prefix.

Do not configure a Supabase service-role key in the Zionxyos frontend application. v0.3 is designed around the publishable key plus Supabase Auth/RLS.

## 3. Supabase Auth URLs

In Supabase Authentication URL configuration, set the Site URL to the production Zionxyos origin and allow the callback URLs used by your Vercel production/preview setup. Password recovery and signup confirmation return through `/auth/callback`.

## 4. Build settings

The project uses the standard Next.js build command:

```bash
npm install
npm run build
```

Zionxyos v0.3 is pinned to Node.js 24.x and npm 11.x. Run `nvm use 24` before dependency installation and configure Vercel to use Node 24 for this release.

## 5. First deploy

Deploy the application only after `npm run preflight` succeeds in a dependency-complete environment. After deployment, verify `/api/health`; a healthy database-backed deployment returns an HTTP 200 response with `status: "ok"` and version `0.3.0`.

Then perform the smoke tests in `RELEASE_CHECKLIST.md` using separate reader/user/admin test sessions where practical. Do not use the protected sysadmin account as the account you intentionally mute/suspend during testing.

After the production build and smoke-test gate is green, `npm run release:package` may be used to create and integrity-test a clean ZIP plus SHA-256 checksum. Packaging is not a substitute for the production build.

## 6. Configure the future update button

Create a Vercel Deploy Hook for the production branch/project and store its URL as `VERCEL_DEPLOY_HOOK_URL`. After that initial setup, the sysadmin panel can trigger a new immutable Vercel deployment without manually visiting the Vercel dashboard each time.

For the optional update checker, publish a small HTTPS JSON manifest from a trusted location whose exact hostname is listed in `ZIONXYOS_RELEASE_MANIFEST_ALLOWED_HOSTS` and save its URL in **Administration -> System settings**. A minimal future manifest can look like:

```json
{
  "version": "0.4.0",
  "notes": "Release notes for the sysadmin.",
  "url": "https://trusted.example/releases/0.4.0"
}
```

The application checks and records the manifest. It does not download and execute release code. The actual v0.4 code must already be committed/pushed to the source the Vercel hook deploys.

## 7. Media architecture

Uploaded media goes directly from the authenticated browser to Supabase Storage. It does not pass through a Vercel Function request body. Supabase Storage and database policies independently enforce ownership, MIME allowlists, feature switches, and configured size limits.

The bucket is intentionally public because published encyclopedia pages must render those objects for anonymous readers. Treat the Media Library as public encyclopedia storage, not as private user-file storage.

## 8. Maintenance and emergency controls

The sysadmin can use **Administration -> System settings** to disable registrations, article writing, discussions, or media uploads independently. Maintenance mode redirects non-staff visitors to `/maintenance` while allowing staff to sign in and administer the system. Operational endpoints `/api/health`, `/robots.txt`, and `/sitemap.xml` remain reachable so health checks and crawler directives do not disappear during maintenance.

## 9. Rollback

Vercel can redeploy an earlier application commit/deployment, but a database migration rollback is separate. Before applying migration 003, keep a recoverable Supabase backup. If schema rollback is required, restore the matching database backup rather than assuming an older frontend can safely operate against the upgraded schema.


## Final reproducible release gate

After `npm install` has produced the release `package-lock.json`, run `npm run release:final`. It performs `npm ci`, `npm ls --depth=0`, the complete preflight, and final ZIP/checksum packaging. A release-candidate ZIP produced without this gate is not the production artifact.


Set `AUTH_RECOVERY_STATE_SECRET` to an independent random server-only value of at least 32 characters. It signs password-recovery state and the short-lived reset grant; never expose it through a `NEXT_PUBLIC_` variable.
