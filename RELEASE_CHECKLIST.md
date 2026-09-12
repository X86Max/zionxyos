# Zionxyos v0.3.0 — Release Checklist

Complete this checklist before promoting v0.3 to the public production deployment.

## Build and configuration

- [ ] Node.js 24.x and npm 11.x are active (`nvm use 24`).
- [ ] `npm install` completes and `package-lock.json` is present and reviewed.
- [ ] `npm run validate:release` passes.
- [ ] `npm run typecheck` passes.
- [ ] `npm run lint` passes.
- [ ] `npm run build` passes.
- [ ] `NEXT_PUBLIC_SITE_URL` is the real HTTPS production origin.
- [ ] `RATE_LIMIT_SALT` is a long random production secret.
- [ ] No `.env.local`, service-role key, or other production secret is committed into the release.

## Database and authentication

- [ ] A recoverable Supabase backup exists before migration 003 is applied.
- [ ] Migration order is correct for the starting version.
- [ ] Exactly one intended account has `role = 'sysadmin'`.
- [ ] A second sysadmin cannot be assigned through the web UI.
- [ ] Sysadmin Administration access requires TOTP MFA/AAL2.
- [ ] Admin Administration access requires TOTP MFA/AAL2.
- [ ] A normal user cannot read private profile/admin fields through PostgREST.
- [ ] Anonymous readers can read only the intended public profile projection.

## Registration and legal consent

- [ ] Registration requires Terms, Privacy Policy, and Community Guidelines acceptance.
- [ ] Email confirmation callback works when enabled in Supabase.
- [ ] Existing account without the current legal version is sent to `/legal/accept`.
- [ ] Accepted legal version/time is recorded.
- [ ] Public legal contact information is configured before launch.
- [ ] Final legal text has received whatever professional review the operator considers necessary.

## Taxonomy and editor

- [ ] Fresh v0.3 has no sample Article Types, Categories, Tags, or articles.
- [ ] Sysadmin can create the first Article Type.
- [ ] Sysadmin can define required/optional infobox fields for an Article Type.
- [ ] Sysadmin can create a root Category and nested Subcategories.
- [ ] Attempting to create a category cycle is rejected.
- [ ] Sysadmin can create a Controlled Tag.
- [ ] Normal users can select but cannot create/rename/move/delete taxonomy.
- [ ] Custom infobox fields can be added in the editor.
- [ ] Required infobox fields are enforced by the normal editor UI.

## Editorial workflow

- [ ] User can save a private draft.
- [ ] User can submit a complete revision for review.
- [ ] Submitted pending revision is no longer editable by the contributor.
- [ ] Editing a published article leaves the current public version online.
- [ ] Admin review shows rendered preview and diff.
- [ ] Admin cannot approve their own submitted revision when using the `admin` role.
- [ ] Request Changes requires a reviewer note and returns the revision to the contributor.
- [ ] Reject requires a reviewer note.
- [ ] Approval publishes only normalized controlled taxonomy.
- [ ] Approval rejects missing/inactive Article Types or inactive selected taxonomy.
- [ ] Public history/diff contains approved revisions only.

## Editorial notices and canonical taxonomy

- [ ] Sysadmin can create, edit, disable, and delete an unused editorial notice template.
- [ ] Admin can assign an active notice to an `open` or `admin` page after MFA.
- [ ] Admin cannot assign/remove a notice on a `sysadmin`-protected page.
- [ ] Direct PostgREST insertion cannot forge `assigned_by`, attach an inactive template, or bypass page protection.
- [ ] Canonical `article_categories` and `article_tags` reject direct browser writes; approval remains the publication path.

## Media

- [ ] Image upload works browser -> Supabase Storage.
- [ ] Video upload works browser -> Supabase Storage.
- [ ] A representative multi-megabyte upload does not post the file through a Next/Vercel Server Action.
- [ ] JPEG, PNG, WebP, GIF, MP4, WebM, and Ogg behavior matches the documented allowlist.
- [ ] Renamed/fake file with a mismatched signature is rejected by the normal upload UI.
- [ ] Storage policy rejects an object outside the authenticated user's folder.
- [ ] Storage/database policies reject disallowed MIME types and oversize objects.
- [ ] System Settings size limits are reflected in the contributor editor.
- [ ] Saving while a direct upload is in progress is blocked.
- [ ] Existing user media can be selected from the Media Library.
- [ ] Stored-media rendering reconstructs the public URL from the registered bucket/object path.
- [ ] Sysadmin cannot retire media that is still referenced by an article/revision.

## Moderation and operations

- [ ] Warning works.
- [ ] Mute blocks contribution but not public reading.
- [ ] Timed suspension expires according to `moderation_actions`.
- [ ] Permanent ban requires sysadmin authority.
- [ ] Protected sysadmin account cannot be moderated through normal staff controls.
- [ ] Report workflow can move through reviewing/resolved/dismissed.
- [ ] Direct PostgREST article/revision, discussion, and report writes hit the same database rate-limit boundary instead of bypassing the Next.js UI.
- [ ] Page protection behaves as expected.
- [ ] `open` pages can be edited by eligible contributors, `admin` pages only by MFA-verified Admin/Sysadmin, and `sysadmin` pages only by the MFA-verified Sysadmin.
- [ ] A direct PostgREST request cannot bypass page protection or pre-set privileged canonical article fields on a contributor draft.
- [ ] A normal Admin can inspect a sysadmin-protected page but cannot feature it, change its protection, edit its pending revision, or approve it.
- [ ] `View as regular user` changes effective UI behavior without changing the database role.
- [ ] Audit log records important administrative/editorial operations.
- [ ] Approved/rejected revisions and their normalized category/tag relations cannot be directly rewritten or hard-deleted by staff browser sessions.
- [ ] Canonical article content cannot be rewritten by direct Sysadmin UPDATE outside review/retirement workflows.
- [ ] Media metadata cannot be retargeted after upload, and referenced media cannot be retired through direct UPDATE.
- [ ] Sysadmin retirement hides a canonical article without deleting its revisions, and restore brings it back.
- [ ] Neither Admin nor Sysadmin can hard-delete a published/canonical article through application RLS.

## Account security

- [ ] A signed-in user can open `/dashboard/security`.
- [ ] A normal password change requires the current password and confirmation of the new password.
- [ ] Email-change requests follow the configured Supabase Auth confirmation behavior.
- [ ] `Sign out other sessions` invalidates other refresh-token sessions while keeping the current session active.
- [ ] Admin/Sysadmin accounts still require MFA/AAL2 before Administration is available.

## Production surfaces

- [ ] `/robots.txt` excludes private/admin routes.
- [ ] `/sitemap.xml` lists only intended public surfaces.
- [ ] `/api/health` returns HTTP 200 on a healthy production database.
- [ ] 404 page renders correctly.
- [ ] Application error boundary renders and retry works.
- [ ] Classic wiki layout is usable on desktop and mobile widths.
- [ ] English-only interface sweep is clean.

## Maintenance and updater

- [ ] Maintenance mode redirects non-staff visitors and preserves staff access.
- [ ] `/api/health`, `/robots.txt`, and `/sitemap.xml` remain reachable while maintenance mode is enabled.
- [ ] Registrations can be disabled independently.
- [ ] Article writing can be disabled without automatically disabling discussions/media.
- [ ] Media/image/video switches operate independently as documented.
- [ ] Trusted release manifest check handles success and failure safely.
- [ ] Production release-manifest hostname is explicitly listed in `ZIONXYOS_RELEASE_MANIFEST_ALLOWED_HOSTS`; a non-allowlisted host is rejected before any optional Bearer token is sent.
- [ ] Vercel Deploy Hook is stored only as a server environment secret.
- [ ] System Update page never accepts or executes arbitrary uploaded code.
- [ ] Triggering the deploy hook requires the exact `DEPLOY` confirmation word in addition to a sysadmin MFA/AAL2 session.
- [ ] Triggering the deploy hook creates a new Vercel deployment and records the attempt.
- [ ] Update/deploy history rows can only be created through the protected Sysadmin RPC; browser sessions cannot forge actor/timestamp/details directly.

## Release package

- [ ] `npm run release:package` succeeds only after `validate:release` is green.
- [ ] The generated ZIP passes `unzip -t` integrity testing.
- [ ] The generated `.sha256` checksum matches the ZIP.
- [ ] The archive contains `.env.example` but no local `.env*` secrets, `.next`, `node_modules`, or `*.tsbuildinfo` artifacts.

## Reproducible final artifact

- [ ] `npm run release:final` completes successfully.
- [ ] The finalizer completes `npm ci` from `package-lock.json`.
- [ ] `npm ls --depth=0` reports a valid top-level dependency tree.
- [ ] TypeScript, ESLint, and `next build` all pass inside the finalizer.
- [ ] `zionxyos-v0.3-final.zip` and its `.sha256` sidecar are produced only after the full gate.

## Final decision

- [ ] Production build is green.
- [ ] Database backup is confirmed.
- [ ] Critical reader/user/admin/sysadmin smoke tests are green.
- [ ] v0.3 is ready to promote.

- [ ] `AUTH_RECOVERY_STATE_SECRET` is a production-only random value of at least 32 characters.
- [ ] Direct navigation to `/update-password` is rejected without a valid email-bound recovery flow.
- [ ] A valid recovery email grants password reset only to the recovered user and expires shortly after use.
