# Zionxyos v0.3.0 — Production Release

Zionxyos is a collaborative encyclopedia for an original fictional universe, built with **Next.js 16, React 19, TypeScript, Supabase, and Vercel**. The v0.3 release keeps the intentionally classic, information-dense wiki interface while adding production administration, controlled taxonomy, structured infoboxes, media uploads, legal consent, MFA-protected staff access, and a safe deployment-control panel.

> **No fictional sample content is seeded.** Zionxyos does not create example articles, article types, categories, subcategories, tags, creatures, regions, characters, or events. The sysadmin defines the taxonomy and the community creates the content through the application.

## Roles

Zionxyos has four practical access levels:

- **Reader** — an anonymous visitor. Readers can browse published encyclopedia content but cannot create or edit articles.
- **User** — a signed-in contributor. Users can create drafts and submit new or edited revisions for review. They cannot publish directly.
- **Admin** — a staff member who can review revisions, moderate users, resolve reports, and perform basic editorial administration. Administrative access requires MFA/AAL2.
- **Sysadmin** — the single protected operator account. The sysadmin controls taxonomy, roles, media administration, system settings, maintenance mode, release configuration, and deployment controls. The web interface never assigns the sysadmin role.

The database enforces a single sysadmin invariant. Promoting the first sysadmin is an intentional out-of-band bootstrap operation in the Supabase SQL Editor.

## Editorial model

Published content and submitted revisions are separate records. Editing a live page never removes the current public version while the new revision is waiting for review.

```text
published article
      |
      +-- remains public
      |
      +-- proposed revision
             |
             +-- draft
             +-- pending review
             +-- changes requested
             +-- approved -> becomes current public revision
             +-- rejected
```

The review screen provides a rendered preview, a line-by-line diff for edits to published pages, and explicit actions to approve, request changes, reject, or open a separate administrative revision editor.

## Controlled taxonomy

Taxonomy is owned by the sysadmin and starts empty.

**Article Types** define semantic page types and their structured infobox schema. **Categories** form a hierarchical tree with arbitrary practical nesting through parent categories. **Controlled Tags** are reusable labels that contributors may select but may not create from the article editor.

A database trigger rejects category cycles. Categories and tags are stored through normalized relationship tables; the legacy text arrays are synchronized from controlled taxonomy during approval for compatibility with existing wiki/search code.

## Structured infoboxes

Each Article Type can define infobox fields with a key, label, placeholder, and required flag. The article editor renders those fields automatically after the contributor chooses an Article Type. Contributors may add custom infobox fields for exceptional information without writing a Markdown table manually.

## References and wiki links

The Markdown editor supports normal Markdown/GFM plus Zionxyos wiki syntax:

```text
[[Article name]]
[[Article name|display text]]
```

The citation builder inserts structured markers such as:

```text
{{cite|name=source|title=Source title|url=https://example.com|author=Author|site=Publication|date=2026|accessed=September 10, 2026}}
```

Those markers render as numbered inline references such as `[1]` and are collected into an automatic **References** section with backlinks.

## Media

Contributors can upload supported images and videos directly from their computer while editing an article. Uploads use this path:

```text
browser -> Supabase Storage -> media metadata -> article/revision media ID
```

The file body does **not** pass through a Next.js Server Action or Vercel Function. This avoids using the application server as a large-file relay. Client-side MIME/signature checks provide immediate feedback, while Supabase Storage bucket restrictions, RLS, owner folders, feature switches, and database size/MIME checks are the authoritative controls.

Supported v0.3 formats:

- Images: JPEG, PNG, WebP, GIF
- Video: MP4, WebM, Ogg
- Storage hard cap: 50 MiB per object
- Default image limit: 10 MiB
- Default video limit: 50 MiB

The sysadmin can lower the application limits in **Administration -> System settings**. Uploaded encyclopedia media is intentionally public-addressable; private or sensitive files must not be uploaded.

## Community and moderation

Zionxyos includes article discussions, reports, a watchlist, notifications, public contributor profiles, revision history, backlinks, recent changes, related articles, page protection, featured pages, internal staff notes, and an audit log.

Moderation actions include warning, mute, suspension, and ban, with reason and optional expiry. Permanent bans and system-level controls remain protected by the sysadmin role. Timed moderation is stored in `moderation_actions`; the old `profiles.suspended` flag is retained only for legacy/manual disabling.

## Editorial notices

Staff can attach reusable editorial banners to published pages without rewriting article content. Notice templates are created, edited, disabled, and deleted only by the protected sysadmin. Admins may assign or remove **active** templates only on pages permitted by the same MFA-backed `can_edit_article(...)` capability used by review and page protection. Canonical article taxonomy is not browser-writable; normalized `article_categories` and `article_tags` are updated only by protected publication/maintenance routines.

## Legal consent

Registration requires explicit acceptance of the current **Terms of Use**, **Privacy Policy**, and **Community Guidelines**. Accepted policy versions and timestamps are recorded. Existing users who have not accepted the current versions are sent to the re-consent page before they can contribute.

The included legal pages are practical project templates written with Brazilian data-protection concepts, including LGPD considerations, in mind. They are **not legal advice and not a guarantee of compliance**. Obtain qualified legal review before relying on the final text for a public production service.

Current policy version: `2026-09-09-v1`.

## Account security

Signed-in users have an **Account security** page at `/dashboard/security`. It supports normal password changes that require the current password, email-change requests through Supabase Auth, and signing out refresh-token sessions on other browsers/devices while keeping the current session. Staff accounts also link directly to the TOTP MFA verification flow used by Administration.

Administrative access is still controlled separately by MFA/AAL2. Password or email controls do not provide a route to assign roles, bypass page protection, or disable MFA requirements.

## Production security

The UI is not the security boundary. Important controls are also enforced in Supabase/Postgres:

- Row Level Security on application tables;
- MFA/AAL2 checks for administrative and sysadmin capabilities;
- one protected sysadmin invariant;
- page protection is enforced in the database, not only in the UI: `open` allows eligible contributors, `admin` requires an MFA/AAL2 Admin or Sysadmin, and `sysadmin` requires the MFA/AAL2 Sysadmin;
- contributor draft INSERT/UPDATE policies prevent clients from pre-setting or changing privileged canonical metadata such as featured/protection/deletion/publication state;
- no web UI path for assigning the sysadmin role;
- controlled review RPC for publication;
- pending contributor revisions become immutable after submission;
- normalized taxonomy is canonicalized again during approval;
- article type and media validity are rechecked before publication;
- private profile fields are separated from the public profile projection;
- authenticated account-state helper RPCs are bound to the caller;
- upload ownership, kind, MIME type, size, and feature switches are checked in Storage/database policies;
- managed-media URLs are reconstructed from trusted bucket/object paths by server rendering code;
- rate limiting for registration/login/password recovery, plus database-bound throttling for article/revision writes, reports, and discussions so direct PostgREST calls do not bypass those limits; browser media uploads also pass an authenticated upload throttle before Storage;
- audit logging for important administrative/editorial actions;
- security headers and a Content Security Policy in the Next.js configuration;
- no arbitrary HTML execution through Markdown;
- soft-deleted pages are excluded from public search, random-page resolution, and wiki-link resolution.
- canonical articles use sysadmin soft retirement/restoration; application sessions can hard-delete only the contributor’s own unpublished draft, preserving published revision history.

## System update panel

The sysadmin panel at `/admin/system` is intentionally not a remote-code-execution feature. It can:

- display the running application version and recorded database migrations;
- check a sysadmin-configured trusted HTTPS release manifest whose hostname is also allowlisted server-side in production;
- record update checks and deployment attempts;
- trigger a preconfigured **Vercel Deploy Hook** stored only in server environment variables.

It does **not** accept an arbitrary ZIP, execute uploaded scripts, rewrite the running application filesystem, or apply database migrations automatically. A future release such as v0.4 must already exist in the trusted deployment source. Once the Vercel Deploy Hook is configured, the sysadmin panel can trigger that deployment without manually rebuilding the project in the Vercel dashboard.

## Requirements

- Node.js 24.x (the release line is pinned in `.nvmrc` and `package.json`)
- npm 11.x
- a Supabase project
- a Vercel project for production deployment

## Environment

Copy `.env.example` to `.env.local` for local development:

```env
NEXT_PUBLIC_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_REPLACE_ME
NEXT_PUBLIC_SITE_URL=http://localhost:3000
RATE_LIMIT_SALT=replace-with-a-long-random-secret

# Optional server-only deployment integration
ZIONXYOS_RELEASE_MANIFEST_ALLOWED_HOSTS=raw.githubusercontent.com
ZIONXYOS_UPDATE_WEBHOOK_TOKEN=
VERCEL_DEPLOY_HOOK_URL=
```

Never expose a Supabase service-role key in the browser or in `NEXT_PUBLIC_*` variables.

## Database installation

For a clean database, execute migrations in order:

```text
supabase/migrations/001_initial.sql
supabase/migrations/002_wiki_update.sql
supabase/migrations/003_production_release.sql
```

For an existing v0.2 database, execute only `003_production_release.sql`. See `UPGRADE_FROM_V0.2.md`.

For an existing v0.1 database, execute `002_wiki_update.sql` first and then `003_production_release.sql`. See `UPGRADE_FROM_V0.1.md`.

## Bootstrap the only sysadmin

Create the intended operator account normally, confirm its email, then perform the one-time bootstrap from the Supabase SQL Editor:

```sql
update public.profiles
set role = 'sysadmin'
where id = (
  select id from auth.users
  where email = 'YOUR_OPERATOR_EMAIL'
);
```

Do not use this procedure to create additional sysadmins. v0.3 enforces at most one sysadmin. The account will be required to enroll/verify MFA before entering Administration.

## Local verification

With registry access and dependencies installed:

```bash
npm install
npm run preflight
npm run dev
```

`npm run preflight` runs the release validator, TypeScript type checking, ESLint, and a production Next.js build. The shipped `VALIDATION_REPORT.md` records the dependency-free static validation performed while preparing the release; it does not replace a real production build.

For the production artifact, first run `npm install` once to generate/update `package-lock.json` under Node 24/npm 11, then run `npm run release:final`. The finalizer performs a clean `npm ci`, verifies the installed top-level dependency tree with `npm ls --depth=0`, runs the full preflight, and only then creates `zionxyos-v0.3-final.zip` plus its SHA-256 checksum.

After a green preflight, `npm run release:package` creates a clean release-candidate ZIP in the parent directory, tests the ZIP with `unzip`, and writes a matching `.sha256` checksum file. The packager tolerates normal local validation artifacts such as `.env.local`, `.next`, `node_modules`, and root TypeScript build metadata, but explicitly excludes them from the archive and verifies that none were packaged.

## Main routes

```text
/                                  Main page
/search                            Search
/categories                        Hierarchical category index
/recent-changes                    Recent public changes
/random                            Random article
/special                           Special pages
/article/[slug]                    Published article
/article/[slug]/discussion         Article discussion
/article/[slug]/history            Public revision history
/article/[slug]/backlinks          What links here
/u/[username]                      Public contributor profile
/dashboard                         Contributor dashboard
/dashboard/articles/new            Create article
/dashboard/media                   User media library
/dashboard/security                Password, email, and session security
/admin                             Administration overview
/admin/review                      Review queue
/admin/users                       Users and moderation
/admin/notices                     Editorial notice templates and assignments
/admin/articles                    Article administration
/admin/reports                     Reports
/admin/logs                        Audit log
/admin/taxonomy                    Sysadmin taxonomy management
/admin/media                       Sysadmin media management
/admin/settings                    Sysadmin system settings
/admin/system                      Sysadmin release/deployment controls
/admin/health                      Sysadmin production diagnostics
/api/health                        Production health endpoint
```

## Deployment

Read `RELEASE_NOTES_0.3.0.md` for this release, `VERCEL_DEPLOY.md` before the first production deployment, and `RELEASE_CHECKLIST.md` for the final smoke test.

## License

No license file is included in this release package. Add the license that matches how you intend Zionxyos source code and contributed content to be reused before publishing the repository publicly.


### Password-recovery signing secret

Production deployments require `AUTH_RECOVERY_STATE_SECRET` (at least 32 random characters). Zionxyos signs the email-bound recovery state and the short-lived HttpOnly password-reset grant so a normal authenticated session cannot navigate directly to `/update-password` and bypass the current-password flow.
