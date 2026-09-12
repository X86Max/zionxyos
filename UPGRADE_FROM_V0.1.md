# Upgrade Zionxyos v0.1 -> v0.3.0

A v0.1 database must pass through the v0.2 schema before the v0.3 production migration.

## Safe order

1. Back up the current Supabase database.
2. Preserve `.env.local`.
3. Replace the application code with v0.3.
4. In the Supabase SQL Editor, run:

```text
supabase/migrations/002_wiki_update.sql
supabase/migrations/003_production_release.sql
```

Do **not** run `001_initial.sql` again on an existing v0.1 database.

Migration 002 introduces the revision/moderation/community model and imports existing v0.1 article state into revision history. Migration 003 then adds production taxonomy, media, legal consent, role separation, MFA, settings, updater metadata, and additional RLS hardening.

The migrations do not create fictional sample articles or a default fictional taxonomy.

## After the database upgrade

Add `RATE_LIMIT_SALT` to the local/production environment, install dependencies, and run:

```bash
npm install
npm run preflight
```

The protected sysadmin account will be required to enroll or verify TOTP MFA before entering Administration. Then create the project taxonomy in **Administration -> Taxonomy**.

Use `VERCEL_DEPLOY.md` and `RELEASE_CHECKLIST.md` before the first v0.3 production deployment.

## Rollback

There is no automatic SQL downgrade. A full rollback requires restoring the pre-upgrade database backup together with the corresponding application version.
