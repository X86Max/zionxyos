# Zionxyos v0.3.0 — Production Foundation

Zionxyos v0.3.0 turns the v0.2 classic-wiki prototype into a production-oriented collaborative encyclopedia foundation for an original fictional universe.

## Highlights

- English-only public, contributor, authentication, moderation, and administration UI.
- Guest reading plus `user`, `admin`, and one protected `sysadmin` account role.
- MFA/AAL2 enforcement for privileged Administration actions.
- Published-page revision workflow: proposed edits wait for review without replacing the current public revision.
- Database-authoritative page protection with `open`, `admin`, and `sysadmin` levels.
- Sysadmin-defined Article Types with structured infobox schemas.
- Hierarchical categories and controlled tags with no free-form taxonomy creation from the article editor.
- Category merge/reparent protections and database cycle prevention.
- Browser-to-Supabase image/video uploads, Media Library, ownership checks, MIME/size controls, and protected retirement.
- Article discussions, reports, watchlist, notifications, public contributor profiles, history, diffs, backlinks, related pages, featured pages, and Random Article.
- Editorial notice templates with sysadmin-only template management and MFA/page-protection-aware staff assignment.
- Canonical article category/tag relations are no longer browser-writable; publication routines own canonical taxonomy.
- Immutable legal-acceptance history for Terms of Use, Privacy Policy, and Community Guidelines.
- System settings, emergency feature switches, maintenance mode, site announcements, health diagnostics, SEO metadata, and error/loading states.
- Safe updater foundation using a trusted HTTPS release manifest and server-side Vercel Deploy Hook; no uploaded code or arbitrary ZIP execution.
- Account Security page for password changes, email-change requests, other-session logout, and staff MFA access.
- Release validator and clean ZIP/checksum packager.
- Approved/rejected revision rows and their normalized taxonomy are immutable to direct browser mutation, including Sysadmin sessions outside protected review flows.
- Canonical article updates use scoped review/retirement workflows; direct staff updates are limited to protection/featured metadata.
- Media object identity/ownership/type metadata is immutable after upload; retirement/restore is guarded and audited.
- System update history is browser-read/RPC-write so deploy/check audit rows cannot be forged directly.

## Content policy for this release

No fictional sample content is seeded. No fictional sample articles, Article Types, categories, or controlled tags are seeded by v0.3. The sysadmin creates the real Zionxyos taxonomy and the community creates the encyclopedia content through the application.

## Database upgrade

Existing v0.2 installations run only:

```text
supabase/migrations/003_production_release.sql
```

Existing v0.1 installations must run `002_wiki_update.sql` before `003_production_release.sql`. Clean databases run `001`, `002`, then `003` in order. Read the matching upgrade guide before applying anything to a production database.

## Production gate

The release is not production-approved merely because the dependency-free validator is green. Before applying migration 003 to the production project or promoting the release, use Node 24.x/npm 11.x and run in an environment with npm registry access:

```bash
npm install
npm run preflight
```

`preflight` requires the release validator, full TypeScript typecheck, ESLint, and `next build` to succeed. After that gate, run the smoke tests in `RELEASE_CHECKLIST.md`. The production artifact is created with `npm run release:final`, which requires `package-lock.json`, re-installs with `npm ci`, verifies `npm ls --depth=0`, repeats the complete preflight, and only then packages the final ZIP.

## Packaging

`npm run release:package` creates `zionxyos-v0.3-rc.zip` in the parent directory, tests the archive, excludes common private/generated artifacts, and emits `zionxyos-v0.3-rc.zip.sha256`.

The archive produced before a real dependency-complete `npm run preflight` is a **release candidate only**, not a production-approved final build.
