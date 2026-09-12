# Upgrade from v0.2 to Zionxyos v0.3.0

This guide assumes the existing v0.2 Supabase database is already using `001_initial.sql` and `002_wiki_update.sql`.

## Before upgrading

1. Create a Supabase database backup or an equivalent recoverable snapshot.
2. Preserve the current `.env.local` outside the release folder.
3. Confirm exactly one account is intended to be the sysadmin. The v0.3 migration creates a uniqueness invariant for that protected role; a database that already contains multiple sysadmins will intentionally fail instead of choosing one silently.
4. Keep the existing v0.2 deployment available until the v0.3 preflight and smoke tests pass.

## Update the application files

Replace the v0.2 application code with the v0.3 release, then recreate `.env.local` from your preserved values. Add a strong random `RATE_LIMIT_SALT`.

Optional production update controls use server-only variables:

```env
VERCEL_DEPLOY_HOOK_URL=
ZIONXYOS_UPDATE_WEBHOOK_TOKEN=
```

Do not prefix those variables with `NEXT_PUBLIC_`.

## Database migration

For a v0.2 database, run **only**:

```text
supabase/migrations/003_production_release.sql
```

Do not run `001_initial.sql` or `002_wiki_update.sql` again on an already-upgraded v0.2 database.

The v0.3 migration adds or hardens:

- `user`, `admin`, and singular `sysadmin` roles;
- legal-consent versions/history;
- MFA/AAL2 administrative enforcement;
- Article Types and structured infobox schemas;
- hierarchical Categories with cycle prevention;
- Controlled Tags;
- normalized article/revision taxonomy tables;
- Supabase Storage media metadata and the `zionxyos-media` bucket;
- media ownership/MIME/size RLS restrictions;
- public-profile projection and private profile protections;
- system settings and emergency feature switches;
- maintenance mode and announcements;
- migration/update history;
- safer rate limiting and publication RPCs;
- soft-delete-aware search/link/random helpers;
- English replacements for exact system-generated legacy notification strings.

The migration does not seed fictional taxonomy or encyclopedia articles. Existing user-authored article text is not translated or rewritten.

## MFA after upgrade

Existing `admin` and `sysadmin` profiles are marked as requiring MFA. The first attempt to enter Administration without an AAL2 session redirects to `/mfa`, where a TOTP authenticator can be enrolled or verified.

## Taxonomy after upgrade

No default v0.3 taxonomy is created. Open **Administration -> Taxonomy** as the sysadmin and create the Article Types, infobox schemas, Categories/Subcategories, and Controlled Tags that belong to your universe.

If v0.2 content already has legacy category/tag text, preserve and review it manually before deciding how it maps to the new controlled taxonomy. New v0.3 publication uses the normalized controlled relationships as the authoritative taxonomy.

## Media after upgrade

The migration creates a public-addressable Supabase Storage bucket named `zionxyos-media` with a 50 MiB hard object cap and an allowlist for supported image/video MIME types. Application upload limits default to 10 MiB for images and 50 MiB for video and may be lowered by the sysadmin.

Media uploads travel directly from the browser to Supabase Storage. Article/revision saves submit media IDs rather than carrying the file bytes through Vercel Functions.

## Verification

With npm registry access:

```bash
rm -rf node_modules .next
npm install
npm run preflight
```

Then follow `RELEASE_CHECKLIST.md`. Do not promote the deployment to production until the production build and the critical role/review/media smoke tests pass.

## Rollback note

The release does not include an automatic SQL downgrade. If rollback is required after applying migration 003, restore the database backup together with the matching v0.2 application deployment. Rolling the application code back while leaving a partially incompatible database state is not a complete rollback strategy.
