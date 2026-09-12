import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { execSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const root = process.cwd();
let passed = 0;
let warnings = 0;
let failed = 0;
const details = [];

function pass(message) { passed += 1; details.push(["PASS", message]); console.log(`PASS  ${message}`); }
function warn(message) { warnings += 1; details.push(["WARN", message]); console.log(`WARN  ${message}`); }
function fail(message) { failed += 1; details.push(["FAIL", message]); console.log(`FAIL  ${message}`); }
function exists(relative) { return fs.existsSync(path.join(root, relative)); }
function read(relative) { return fs.readFileSync(path.join(root, relative), "utf8"); }
function allFiles(directory, extensions) {
  const output = [];
  const walk = (current) => {
    if (!fs.existsSync(current)) return;
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (!extensions || extensions.some((extension) => entry.name.endsWith(extension))) output.push(full);
    }
  };
  walk(path.join(root, directory));
  return output;
}

const required = [
  "package.json", ".nvmrc", "next.config.ts", "proxy.ts", ".env.example",
  "supabase/migrations/001_initial.sql", "supabase/migrations/002_wiki_update.sql", "supabase/migrations/003_production_release.sql",
  "src/app/page.tsx", "src/app/layout.tsx", "src/app/not-found.tsx", "src/app/error.tsx", "src/app/global-error.tsx", "src/app/loading.tsx", "src/app/robots.ts", "src/app/sitemap.ts",
  "src/app/api/health/route.ts", "src/app/admin/health/page.tsx", "src/app/admin/system/page.tsx", "src/app/admin/taxonomy/page.tsx", "src/app/admin/settings/page.tsx", "src/app/admin/notices/page.tsx",
  "src/app/admin/media/page.tsx", "src/app/legal/terms/page.tsx", "src/app/legal/privacy/page.tsx", "src/app/legal/guidelines/page.tsx",
  "src/components/ArticleForm.tsx", "src/components/DirectMediaUpload.tsx", "src/components/MfaPanel.tsx",
  "src/app/dashboard/security/page.tsx", "src/lib/media-server.ts", "src/lib/media-url.ts", "src/lib/password-recovery.ts", "src/lib/wiki-presentation.ts", "src/lib/site-url.ts", "src/lib/supabase/config.ts", "src/lib/version.ts",
  "scripts/package-release.mjs", "scripts/finalize-release.mjs", "README.md", "UPGRADE_FROM_V0.1.md", "UPGRADE_FROM_V0.2.md", "VERCEL_DEPLOY.md", "RELEASE_CHECKLIST.md", "RELEASE_NOTES_0.3.0.md",
];
const missingRequired = required.filter((file) => !exists(file));
missingRequired.length ? fail(`Missing required release files: ${missingRequired.join(", ")}`) : pass(`All ${required.length} required release files are present`);

const pkg = JSON.parse(read("package.json"));
pkg.version === "0.3.0" ? pass("package.json version is 0.3.0") : fail(`package.json version is ${pkg.version}`);
const nvmrc = read(".nvmrc").trim();
pkg.engines?.node === "24.x" && pkg.engines?.npm === "11.x" && /^npm@11\./.test(pkg.packageManager || "") && /^24(?:\.|$)/.test(nvmrc) ? pass("Node.js runtime is pinned consistently to 24.x") : fail("Node/npm runtime pins are inconsistent; expected Node 24.x, npm 11.x, packageManager npm@11.x, and .nvmrc 24");
/^\^?24\./.test(pkg.devDependencies?.["@types/node"] || "") ? pass("Node.js type definitions match the pinned Node 24 runtime") : fail("@types/node does not match the pinned Node 24 runtime");
const versionSource = read("src/lib/version.ts");
const appVersion = versionSource.match(/APP_VERSION\s*=\s*["']([^"']+)/)?.[1];
appVersion === pkg.version ? pass("Application version constant matches package.json") : fail(`Application version mismatch: package=${pkg.version}, APP_VERSION=${appVersion || "missing"}`);
const healthSource = read("src/app/api/health/route.ts");
/import \{ APP_VERSION \} from ["']@\/lib\/version["']/.test(healthSource) && /version:\s*APP_VERSION/.test(healthSource) ? pass("Health endpoint reports the centralized application version") : fail("Health endpoint has a hard-coded or disconnected version");
for (const script of ["dev", "build", "start", "lint", "typecheck", "validate:release", "preflight", "release:package", "release:final"]) {
  pkg.scripts?.[script] ? pass(`npm script '${script}' is defined`) : fail(`npm script '${script}' is missing`);
}

const adminLayout = read("src/app/admin/layout.tsx");
const dashboardLayout = read("src/app/dashboard/layout.tsx");
/robots:\s*\{\s*index:\s*false/.test(adminLayout) && /robots:\s*\{\s*index:\s*false/.test(dashboardLayout) ? pass("Private admin/dashboard surfaces emit noindex metadata") : fail("Admin/dashboard layouts must explicitly disable indexing");
const segmentErrorSource = read("src/app/error.tsx");
const globalErrorSource = read("src/app/global-error.tsx");
const globalLoadingSource = read("src/app/loading.tsx");
/reset\(\)/.test(segmentErrorSource) && /Something went wrong/.test(segmentErrorSource) && /<html lang=["']en["']>/.test(globalErrorSource) && /<body>/.test(globalErrorSource) && /temporarily unavailable/.test(globalErrorSource) && /aria-busy=["']true["']/.test(globalLoadingSource) && /Please wait/.test(globalLoadingSource) ? pass("Segment error, root-layout global error, and loading states are present") : fail("Segment/global error or loading states are incomplete");

const migration = read("supabase/migrations/003_production_release.sql");
const migrationChecks = [
  ["Migration declares v0.3 production release", /Zionxyos v0\.3/i],
  ["Migration declares prerequisite order", /Run AFTER 001_initial\.sql and 002_wiki_update\.sql/i],
  ["Single protected sysadmin invariant exists", /profiles_single_sysadmin_idx/i],
  ["Hierarchical categories exist", /parent_id uuid references public\.categories/i],
  ["Category-cycle trigger exists", /categories_prevent_cycle/i],
  ["Controlled tags exist", /create table if not exists public\.controlled_tags/i],
  ["Article types exist", /create table if not exists public\.article_types/i],
  ["Media metadata exists", /create table if not exists public\.media_assets/i],
  ["Supabase Storage bucket exists", /'zionxyos-media'/i],
  ["Legal acceptance history exists", /create table if not exists public\.legal_acceptances/i],
  ["MFA-protected admin helper exists", /create or replace function public\.is_admin_mfa/i],
  ["MFA-protected sysadmin helper exists", /create or replace function public\.is_sysadmin_mfa/i],
  ["Settings validation is hardened", /Strict setting validation/i],
  ["Public profile projection exists", /create view public\.public_profiles/i],
  ["Soft-deleted pages are excluded from random", /random_published_article[\s\S]*?deleted_at is null/i],
  ["Soft-deleted pages are excluded from wiki links", /wiki_resolve_links[\s\S]*?deleted_at is null/i],
  ["System migration record is last-stage content", /003_production_release[\s\S]*?commit;/i],
];
for (const [message, rx] of migrationChecks) rx.test(migration) ? pass(message) : fail(message);
const prereqIndex = migration.indexOf("Refuse an out-of-order upgrade before v0.3 mutates anything");
const firstSchemaMutation = migration.search(/create\s+extension|alter\s+table|create\s+table/i);
prereqIndex >= 0 && firstSchemaMutation >= 0 && prereqIndex < firstSchemaMutation && /requires 001_initial\.sql/.test(migration.slice(prereqIndex, prereqIndex + 1200)) && /requires 002_wiki_update\.sql/.test(migration.slice(prereqIndex, prereqIndex + 1600)) ? pass("Migration enforces the 001/002 prerequisite before schema changes") : fail("Migration prerequisite is only documented, not enforced before schema changes");

const beginCount = (migration.match(/^begin;\s*$/gmi) || []).length;
const commitCount = (migration.match(/^commit;\s*$/gmi) || []).length;
beginCount === 1 && commitCount === 1 ? pass("Migration has exactly one top-level BEGIN/COMMIT pair") : fail(`Migration transaction count is BEGIN=${beginCount}, COMMIT=${commitCount}`);

migration.trimEnd().endsWith("commit;") ? pass("Migration ends with COMMIT") : fail("Migration has content after its final COMMIT");
(migration.match(/\$\$/g) || []).length % 2 === 0 ? pass("Migration dollar-quote delimiters are balanced") : fail("Migration has an odd number of $$ delimiters");

function sqlStructuralText(sql) {
  let output = "";
  let i = 0;
  while (i < sql.length) {
    if (sql.startsWith("--", i)) { const end = sql.indexOf("\n", i + 2); i = end < 0 ? sql.length : end; output += "\n"; continue; }
    if (sql.startsWith("/*", i)) { const end = sql.indexOf("*/", i + 2); i = end < 0 ? sql.length : end + 2; output += " "; continue; }
    if (sql[i] === "'") { i += 1; while (i < sql.length) { if (sql[i] === "'" && sql[i + 1] === "'") { i += 2; continue; } if (sql[i] === "'") { i += 1; break; } i += 1; } output += "''"; continue; }
    if (sql[i] === '$') { const match = sql.slice(i).match(/^\$[A-Za-z0-9_]*\$/); if (match) { const tag = match[0]; const end = sql.indexOf(tag, i + tag.length); i = end < 0 ? sql.length : end + tag.length; output += " "; continue; } }
    output += sql[i++];
  }
  return output;
}
const sqlParenProblems = [];
for (const file of ["supabase/migrations/001_initial.sql", "supabase/migrations/002_wiki_update.sql", "supabase/migrations/003_production_release.sql"]) {
  const structural = sqlStructuralText(read(file)); let depth = 0; let bad = false;
  for (const char of structural) { if (char === "(") depth += 1; else if (char === ")") { depth -= 1; if (depth < 0) { bad = true; break; } } }
  if (bad || depth !== 0) sqlParenProblems.push(file);
}
sqlParenProblems.length ? fail(`SQL lexical parenthesis imbalance: ${sqlParenProblems.join(", ")}`) : pass("All shipped migration SQL parentheses are lexically balanced outside strings/comments/function bodies");

// PostgreSQL rejects CREATE OR REPLACE FUNCTION when an existing function with
// the same input signature changes its return type / RETURNS TABLE OUT row type.
// Audit the shipped migration sequence and require an explicit DROP FUNCTION
// before any incompatible replacement so clean 001 -> 002 -> 003 installs are
// caught by the static release gate instead of only by a live database.
function splitSqlArgs(args) {
  const parts = []; let start = 0; let depth = 0;
  for (let i = 0; i < args.length; i += 1) {
    const ch = args[i];
    if (ch === "(") depth += 1;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (ch === "," && depth === 0) { parts.push(args.slice(start, i)); start = i + 1; }
  }
  if (args.slice(start).trim()) parts.push(args.slice(start));
  return parts;
}
function normalizeSqlType(value) {
  return value.toLowerCase().replace(/\s+/g, " ").replace(/\s*([(),\[\]])\s*/g, "$1").trim();
}
function functionInputSignature(name, args) {
  const argTypes = splitSqlArgs(args).map((raw) => {
    let value = raw.trim().replace(/^\b(?:in|inout|variadic)\b\s+/i, "");
    value = value.replace(/\s+default\s+[\s\S]*$/i, "").trim();
    const named = value.match(/^([a-zA-Z_][a-zA-Z0-9_$]*)\s+([\s\S]+)$/);
    return normalizeSqlType(named ? named[2] : value);
  });
  return `${name.toLowerCase()}(${argTypes.join(",")})`;
}
function droppedInputSignature(name, args) {
  const argTypes = splitSqlArgs(args).map((raw) => normalizeSqlType(raw.replace(/\s+default\s+[\s\S]*$/i, "").trim()));
  return `${name.toLowerCase()}(${argTypes.join(",")})`;
}
const migrationReturnShapeProblems = [];
const knownFunctionReturns = new Map();
for (const file of ["supabase/migrations/001_initial.sql", "supabase/migrations/002_wiki_update.sql", "supabase/migrations/003_production_release.sql"]) {
  const sql = read(file);
  const events = [];
  for (const match of sql.matchAll(/create\s+or\s+replace\s+function\s+public\.([a-zA-Z0-9_]+)\s*\(([\s\S]*?)\)\s*(returns\s+[\s\S]*?)(?=\s+language\s+)/gi)) {
    events.push({ kind: "create", index: match.index, name: match[1], args: match[2], returns: normalizeSqlType(match[3]) });
  }
  for (const match of sql.matchAll(/drop\s+function\s+(?:if\s+exists\s+)?public\.([a-zA-Z0-9_]+)\s*\(([^;]*)\)\s*;/gi)) {
    events.push({ kind: "drop", index: match.index, name: match[1], args: match[2] });
  }
  events.sort((a, b) => a.index - b.index);
  for (const event of events) {
    const signature = event.kind === "create" ? functionInputSignature(event.name, event.args) : droppedInputSignature(event.name, event.args);
    if (event.kind === "drop") { knownFunctionReturns.delete(signature); continue; }
    const previous = knownFunctionReturns.get(signature);
    if (previous && previous.returns !== event.returns) {
      const line = sql.slice(0, event.index).split("\n").length;
      migrationReturnShapeProblems.push(`${file}:${line} ${signature} changes ${previous.returns} -> ${event.returns} without DROP FUNCTION`);
    }
    knownFunctionReturns.set(signature, { returns: event.returns, file });
  }
}
migrationReturnShapeProblems.length ? fail(`Incompatible CREATE OR REPLACE return-shape changes: ${migrationReturnShapeProblems.join(" | ")}`) : pass("Migration sequence drops functions before any incompatible return-shape replacement");

const wikiSearchDefinitions = [...migration.matchAll(/create\s+or\s+replace\s+function\s+public\.wiki_search\s*\([\s\S]*?\$\$;\s*/gi)].map((match) => match[0]);
const wikiSearchRankProblems = wikiSearchDefinitions.filter((definition) => /order\s+by\s+rank\s+desc/i.test(definition) && !/\)::real\s+as\s+rank/i.test(definition));
wikiSearchRankProblems.length ? fail("wiki_search orders by rank without aliasing the computed rank projection") : pass("Every wiki_search definition that orders by rank aliases the computed rank projection");

// PostgreSQL resolves function names used by schema-level DDL (notably RLS
// policies and trigger declarations) when that DDL is created. Audit public
// helper calls outside dollar-quoted routine bodies and require every shipped
// helper to have been defined by that point in the 001 -> 002 -> 003 sequence.
const migrationFilesInOrder = [
  "supabase/migrations/001_initial.sql",
  "supabase/migrations/002_wiki_update.sql",
  "supabase/migrations/003_production_release.sql",
];
const shippedFunctionNames = new Set();
for (const file of migrationFilesInOrder) {
  for (const match of read(file).matchAll(/create\s+(?:or\s+replace\s+)?function\s+public\.([a-z0-9_]+)\s*\(/gi)) shippedFunctionNames.add(match[1].toLowerCase());
}
const availableFunctions = new Set();
const earlyFunctionReferences = [];
for (const file of migrationFilesInOrder) {
  const sql = read(file);
  const structural = sqlStructuralText(sql);
  const events = [];
  for (const match of structural.matchAll(/create\s+(?:or\s+replace\s+)?function\s+public\.([a-z0-9_]+)\s*\(/gi)) {
    events.push({ index: match.index ?? 0, kind: "define", name: match[1].toLowerCase() });
  }
  for (const match of structural.matchAll(/public\.([a-z0-9_]+)\s*\(/gi)) {
    const name = match[1].toLowerCase();
    if (!shippedFunctionNames.has(name)) continue;
    const before = structural.slice(Math.max(0, (match.index ?? 0) - 140), match.index ?? 0);
    if (/(?:create\s+(?:or\s+replace\s+)?function|drop\s+function(?:\s+if\s+exists)?|grant\s+execute\s+on\s+function|revoke\s+(?:all|execute)\s+on\s+function)\s*$/i.test(before)) continue;
    events.push({ index: match.index ?? 0, kind: "call", name });
  }
  events.sort((a, b) => a.index - b.index || (a.kind === "define" ? -1 : 1));
  for (const event of events) {
    if (event.kind === "define") { availableFunctions.add(event.name); continue; }
    if (!availableFunctions.has(event.name)) {
      const line = structural.slice(0, event.index).split("\n").length;
      earlyFunctionReferences.push(`${file}:${line} public.${event.name}()`);
    }
  }
}
earlyFunctionReferences.length ? fail(`Schema-level DDL references shipped functions before definition: ${earlyFunctionReferences.join(" | ")}`) : pass("Schema-level DDL only references shipped helper functions after they are defined");


// Database-surface audit: every application table created in the public schema by
// the shipped migrations must have RLS enabled somewhere in the shipped sequence.
const shippedMigrationText = [
  read("supabase/migrations/001_initial.sql"),
  read("supabase/migrations/002_wiki_update.sql"),
  migration,
].join("\n");
const publicTables = [...shippedMigrationText.matchAll(/create\s+table(?:\s+if\s+not\s+exists)?\s+public\.([a-z0-9_]+)/gi)].map((match) => match[1]);
const uniquePublicTables = [...new Set(publicTables)].sort();
const tablesWithoutRls = uniquePublicTables.filter((table) => !new RegExp(`alter\\s+table\\s+public\\.${table}\\s+enable\\s+row\\s+level\\s+security`, "i").test(shippedMigrationText));
tablesWithoutRls.length ? fail(`Public tables without RLS: ${tablesWithoutRls.join(", ")}`) : pass(`Every public application table has RLS enabled (${uniquePublicTables.length}/${uniquePublicTables.length})`);

// SECURITY DEFINER routines are powerful. Inspect the latest definition of every
// routine in migration 003 and require a fixed search_path on each privileged one.
const functionStarts = [...migration.matchAll(/create\s+or\s+replace\s+function\s+public\.([a-z0-9_]+)\s*\(/gi)];
const latestFunctionBlocks = new Map();
for (const match of functionStarts) {
  const start = match.index ?? 0;
  const end = migration.indexOf("\n$$;", start);
  if (end < 0) continue;
  latestFunctionBlocks.set(match[1], migration.slice(start, end + 4));
}
const unsafeDefiners = [...latestFunctionBlocks.entries()]
  .filter(([, block]) => /security\s+definer/i.test(block) && !/set\s+search_path\s*=\s*public/i.test(block))
  .map(([name]) => name);
unsafeDefiners.length ? fail(`SECURITY DEFINER functions without fixed search_path: ${unsafeDefiners.join(", ")}`) : pass(`All latest SECURITY DEFINER functions pin search_path (${[...latestFunctionBlocks.values()].filter((block) => /security\s+definer/i.test(block)).length} checked)`);
const internalRoutineNames = ["handle_new_user","set_updated_at","capture_article_version","audit_article_change","audit_profile_admin_change","audit_revision_change","prevent_category_cycle","protect_profile_privileged_fields","require_mfa_for_privileged_role","enforce_article_permissions","enforce_revision_permissions","enforce_contribution_rate_limit","enforce_discussion_admin_update","enforce_report_admin_update","enforce_revision_taxonomy_limit","sync_article_internal_links","enforce_article_notice_limit"];
const unsealedInternalRoutines = internalRoutineNames.filter((name) => !new RegExp(`revoke all on function public\\.${name}\\(`, "i").test(migration));
unsealedInternalRoutines.length ? fail(`Trigger/internal routines still expose default EXECUTE: ${unsealedInternalRoutines.join(", ")}`) : pass(`Trigger/internal routines are explicitly sealed from browser RPC access (${internalRoutineNames.length} checked)`);

// Repeated CREATE POLICY without a matching DROP is a common migration failure on
// upgrade. Track each policy by table + name, not by name alone.
const policyState = new Map();
const duplicatePolicyCreates = [];
for (const line of migration.split(/\r?\n/)) {
  let match = line.match(/^\s*drop\s+policy\s+if\s+exists\s+"([^"]+)"\s+on\s+([a-z0-9_.]+)\s*;/i);
  if (match) { policyState.set(`${match[2].toLowerCase()}::${match[1]}`, "dropped"); continue; }
  match = line.match(/^\s*create\s+policy\s+"([^"]+)"\s+on\s+([a-z0-9_.]+)/i);
  if (match) {
    const key = `${match[2].toLowerCase()}::${match[1]}`;
    if (policyState.get(key) === "created") duplicatePolicyCreates.push(key);
    policyState.set(key, "created");
  }
}
duplicatePolicyCreates.length ? fail(`Policies recreated without an intervening DROP: ${duplicatePolicyCreates.join(", ")}`) : pass("Policy sequencing has no duplicate CREATE without an intervening DROP");

// Reconstruct the effective policy set across all shipped migrations. Privileged
// bypasses in final RLS must use MFA-aware helpers; raw role probes are reserved for
// trusted internal code and are revoked from browser RPC access.
const effectivePolicies = new Map();
const policyStatements = shippedMigrationText.match(/(?:drop\s+policy\s+if\s+exists\s+"[^"]+"\s+on\s+(?:public\.)?[a-z0-9_]+\s*;|create\s+policy\s+"[^"]+"\s+on\s+(?:public\.)?[a-z0-9_]+[\s\S]*?;)/gi) || [];
for (const statement of policyStatements) {
  const drop = statement.match(/drop\s+policy\s+if\s+exists\s+"([^"]+)"\s+on\s+(?:public\.)?([a-z0-9_]+)/i);
  if (drop) { effectivePolicies.delete(`${drop[2].toLowerCase()}::${drop[1]}`); continue; }
  const create = statement.match(/create\s+policy\s+"([^"]+)"\s+on\s+(?:public\.)?([a-z0-9_]+)/i);
  if (create) effectivePolicies.set(`${create[2].toLowerCase()}::${create[1]}`, statement);
}
const rawPrivilegedPolicies = [...effectivePolicies.entries()]
  .filter(([, statement]) => /public\.is_(?:admin|sysadmin)\s*\(/i.test(statement))
  .map(([key]) => key);
rawPrivilegedPolicies.length ? fail(`Effective RLS policies retain non-MFA privileged role bypasses: ${rawPrivilegedPolicies.join(", ")}`) : pass(`Effective RLS policies contain no raw admin/sysadmin privilege bypasses (${effectivePolicies.size} checked)`);
for (const requiredPolicy of ["notifications::notifications_own_read", "article_versions::versions_author_or_admin_read"]) {
  if (!effectivePolicies.has(requiredPolicy)) fail(`Expected effective privacy policy is missing: ${requiredPolicy}`);
}

const finalHardeningIndex = migration.lastIndexOf("-- Release-candidate hardening:");
const finalHardening = finalHardeningIndex >= 0 ? migration.slice(finalHardeningIndex) : "";
finalHardening ? pass("Release-candidate hardening block is present at the end of migration 003") : fail("Final release-candidate hardening block is missing");
(/drop policy if exists "article_categories_admin_write"/i.test(finalHardening) && /drop policy if exists "article_tags_admin_write"/i.test(finalHardening) && /revoke insert, update, delete on public\.article_categories from anon, authenticated/i.test(finalHardening) && /revoke insert, update, delete on public\.article_tags from anon, authenticated/i.test(finalHardening)) ? pass("Canonical article taxonomy is writable only through the protected publication RPC") : fail("Canonical article_categories/article_tags remain directly writable by browser sessions");
/notice_templates_sysadmin_write[\s\S]*?is_sysadmin_mfa\(auth\.uid\(\)\)/i.test(finalHardening) ? pass("Editorial notice templates are sysadmin-only") : fail("Editorial notice templates are not restricted to the sysadmin");
/notice_templates_public_read_v03[\s\S]*?article_notices[\s\S]*?a\.status='published'[\s\S]*?a\.deleted_at is null[\s\S]*?notice_templates_authenticated_read_v03[\s\S]*?is_admin_mfa/i.test(finalHardening) ? pass("Unused editorial notice template text is hidden from public and regular-authenticated reads") : fail("Public clients can enumerate unused editorial notice templates");
/article_notices_admin_insert_v03[\s\S]*?assigned_by = auth\.uid\(\)[\s\S]*?is_admin_mfa[\s\S]*?can_edit_article\(article_id, auth\.uid\(\)\)[\s\S]*?notice_templates[\s\S]*?n\.active[\s\S]*?article_notices_admin_delete_v03[\s\S]*?can_edit_article\(article_id, auth\.uid\(\)\)/i.test(finalHardening) ? pass("Editorial notice assignment is MFA-, actor-, active-template-, and page-protection-aware") : fail("Editorial notice assignment can bypass actor/template/page-protection controls");
/has_current_legal_acceptance[\s\S]*?uid\s+is\s+not\s+null\s+and\s+uid\s*=\s*auth\.uid\(\)/i.test(finalHardening) ? pass("Legal-acceptance helper is bound to the authenticated caller") : fail("Legal-acceptance helper can probe arbitrary users");
/is_active_user[\s\S]*?uid\s+is\s+not\s+null\s+and\s+uid\s*=\s*auth\.uid\(\)/i.test(finalHardening) ? pass("Account-state helper is bound to the authenticated caller") : fail("Account-state helper can probe arbitrary users");
/has_current_legal_acceptance[\s\S]*?from public\.legal_acceptances la[\s\S]*?la\.user_id = uid/i.test(finalHardening) ? pass("Current legal consent is proven by immutable acceptance history") : fail("Current legal consent still trusts mutable profile metadata");
/Users may only change display name and biography/i.test(finalHardening) && /zionxyos\.legal_accept/i.test(finalHardening) ? pass("Self-service profile updates cannot forge legal or privileged account fields") : fail("Profile self-update trigger does not use a strict field allowlist");
/revoke insert, update, delete on public\.legal_acceptances from anon, authenticated/i.test(finalHardening) ? pass("Legal acceptance history is append-only to browser roles") : fail("Browser roles can mutate legal acceptance history directly");
/mark_notification_read[\s\S]*?user_id=auth\.uid\(\)/i.test(finalHardening) && /revoke insert, update on public\.notifications from anon, authenticated/i.test(finalHardening) ? pass("Notification payloads are immutable to browser roles; users can only acknowledge their own records") : fail("Users can directly rewrite notification payloads");
/check \(protection_level in \(\'open\',\'admin\',\'sysadmin\'\)\)/i.test(finalHardening) && !/check \(protection_level in \(\'open\',\'registered\',\'sysadmin\'\)\)/i.test(finalHardening) ? pass("v0.3 page-protection levels are open/admin/sysadmin") : fail("Legacy registered page protection is still authoritative in final hardening");
/can_edit_article[\s\S]*?uid is not null[\s\S]*?uid = auth\.uid\(\)[\s\S]*?protection_level = 'admin'[\s\S]*?is_admin_mfa[\s\S]*?protection_level = 'sysadmin'[\s\S]*?is_sysadmin_mfa/i.test(finalHardening) ? pass("Database page-edit capability binds caller identity and distinguishes admin/sysadmin protection") : fail("can_edit_article protection capability is incomplete");
/revisions_author_insert[\s\S]*?can_edit_article\(article_id,auth\.uid\(\)\)/i.test(finalHardening) && /revision_categories_write[\s\S]*?can_edit_article\(r\.article_id,auth\.uid\(\)\)/i.test(finalHardening) && /revision_tags_write[\s\S]*?can_edit_article\(r\.article_id,auth\.uid\(\)\)/i.test(finalHardening) ? pass("Revision and revision-taxonomy RLS enforce page protection") : fail("Revision write RLS can bypass page protection");
/admin_review_revision[\s\S]*?Page protection does not permit this reviewer to act on the revision/i.test(finalHardening) ? pass("Review RPC respects page protection before publication") : fail("Review RPC can act through a higher page-protection level");
/Only the sysadmin may manage sysadmin-only page protection/i.test(finalHardening) ? pass("Admin cannot create, alter, or remove sysadmin-only page protection") : fail("Sysadmin-only protection is not guarded against admin mutation");
/articles_author_insert[\s\S]*?featured=false[\s\S]*?protection_level='open'[\s\S]*?current_revision_id is null[\s\S]*?published_at is null[\s\S]*?deleted_at is null/i.test(finalHardening) ? pass("Contributor article INSERT cannot pre-set privileged canonical state") : fail("Contributor article INSERT can pre-set privileged canonical state");
/Contributors cannot change privileged article metadata/i.test(finalHardening) && /to_jsonb\(new\)[\s\S]*?cover_media_id[\s\S]*?original_creator_user_id/i.test(finalHardening) ? pass("Contributor article UPDATE has an explicit canonical-field allowlist") : fail("Contributor article UPDATE lacks privileged metadata protection");
/Canonical article retention hardening/i.test(finalHardening) && /articles_draft_owner_or_admin_delete[\s\S]*?author_id=auth\.uid\(\)[\s\S]*?status='draft'/i.test(finalHardening) && !/articles_draft_owner_or_admin_delete[\s\S]{0,500}?is_sysadmin_mfa/i.test(finalHardening.slice(finalHardening.lastIndexOf("-- Canonical article retention hardening."))) ? pass("Application RLS hard-deletes only the caller's own unpublished draft") : fail("Canonical article hard-delete remains available to privileged application sessions");
const adminActionsSource = read("src/actions/admin.ts");
/sysadmin_set_article_retired[\s\S]*?article\.retired[\s\S]*?article\.restored[\s\S]*?reason/i.test(finalHardening) && /retireArticleAction[\s\S]*?sysadmin_set_article_retired/i.test(adminActionsSource) && /restoreArticleAction[\s\S]*?sysadmin_set_article_retired/i.test(adminActionsSource) ? pass("Sysadmin article retirement/restoration is atomic, audited, and preserves canonical history") : fail("Soft-retire/restore flow is not atomic and audited");
/can_edit_article[\s\S]*?a\.id = article_uuid[\s\S]*?a\.deleted_at is null/i.test(finalHardening) ? pass("Page-edit capability rejects soft-deleted canonical articles") : fail("Page-edit capability can authorize soft-deleted articles");
const reviewRpcIndex = migration.lastIndexOf("create or replace function public.admin_review_revision");
const editCapabilityBeforeReview = migration.lastIndexOf("create or replace function public.can_edit_article", reviewRpcIndex);
(editCapabilityBeforeReview >= 0 && editCapabilityBeforeReview < reviewRpcIndex) ? pass("Page-edit capability is defined before the final review RPC consumes it") : fail("Final review RPC has a forward dependency on can_edit_article");
/revoke all on function public\.moderation_is_active\(uuid,text\) from public, anon, authenticated/i.test(finalHardening) ? pass("Raw moderation-state probe is not exposed to browser roles") : fail("Raw moderation-state probe remains callable");
/Admins must use a finite expiry for mutes and suspensions/i.test(finalHardening) && /caller_role='admin'[\s\S]*?action_kind in \('mute','suspend'\)[\s\S]*?action_expires_at is null/i.test(finalHardening) ? pass("Admin cannot create a permanent ban-equivalent with indefinite mute/suspension") : fail("Admin can create indefinite blocking moderation without sysadmin authority");
/drop policy if exists "moderation_admin_insert"[\s\S]*?drop policy if exists "moderation_admin_update"/i.test(finalHardening) ? pass("Moderation writes are forced through the protected RPC") : fail("Direct moderation table writes remain exposed");
/enforce_contribution_rate_limit[\s\S]*?consume_rate_limit\('article_write','database',120,3600\)[\s\S]*?consume_rate_limit\('discussion','database',40,3600\)[\s\S]*?consume_rate_limit\('report','database',20,3600\)/i.test(finalHardening) ? pass("Article/revision, discussion, and report throttles are enforced at the database boundary") : fail("Authenticated content rate limits can be bypassed through direct PostgREST writes");
/article_write_rate_limit before insert or update on public\.articles[\s\S]*?revision_write_rate_limit before insert or update on public\.article_revisions[\s\S]*?discussion_write_rate_limit before insert on public\.discussion_posts[\s\S]*?report_write_rate_limit before insert on public\.reports/i.test(finalHardening) ? pass("Database rate-limit triggers cover all intended contributor write surfaces") : fail("One or more database rate-limit triggers are missing");
/object_path\s+like\s+auth\.uid\(\)::text\s*\|\|\s*'\/%'/i.test(finalHardening) ? pass("Media metadata is bound to the uploader's Storage folder") : fail("Media metadata object path is not bound to auth.uid()");
/revision_categories_write[\s\S]*?r\.status\s+in\s*\('draft','changes_requested'\)[\s\S]*?revision_tags_write[\s\S]*?r\.status\s+in\s*\('draft','changes_requested'\)/i.test(finalHardening) ? pass("Contributors cannot mutate normalized taxonomy after review submission") : fail("Pending revision taxonomy may remain contributor-writable");
/canonical_categories[\s\S]*?canonical_tags[\s\S]*?revision contains an inactive or missing category[\s\S]*?revision contains an inactive or missing tag/i.test(finalHardening) ? pass("Approval revalidates and canonicalizes controlled taxonomy") : fail("Approval does not fully canonicalize controlled taxonomy");
/published revision requires a title and content[\s\S]*?article type is inactive or missing/i.test(finalHardening) ? pass("Approval refuses empty content and missing/inactive Article Types") : fail("Approval lacks final structural validation");
/cover_image_url=case when r\.cover_media_id is null then r\.cover_image_url else null end/i.test(finalHardening) ? pass("Managed media URLs are not trusted as canonical article metadata") : fail("Approval still trusts client-written managed-media URLs");
const publicMediaLimitDefaults = /\('max_image_bytes',\s*'10485760'::jsonb,[^\n]*,\s*true\)/i.test(migration) && /\('max_video_bytes',\s*'52428800'::jsonb,[^\n]*,\s*true\)/i.test(migration);
const publicMediaLimitHardening = /update\s+public\.site_settings\s+set\s+is_public\s*=\s*true\s+where\s+key\s+in\s*\(\s*'max_image_bytes'\s*,\s*'max_video_bytes'\s*\)/i.test(migration);
(publicMediaLimitDefaults || publicMediaLimitHardening) ? pass("Contributor media limits are exposed as non-sensitive public settings") : fail("Contributor editor cannot reliably read live media size limits");


const forbiddenSeedPatterns = [
  /insert\s+into\s+public\.article_types\s*\([^)]*(?:name|slug)/i,
  /insert\s+into\s+public\.categories\s*\([^)]*(?:name|slug)/i,
  /insert\s+into\s+public\.controlled_tags\s*\([^)]*(?:name|slug)/i,
  /insert\s+into\s+public\.articles\s*\(/i,
];
forbiddenSeedPatterns.some((rx) => rx.test(migration)) ? fail("Migration appears to seed universe taxonomy or article content") : pass("Migration does not seed article types, categories, tags, or articles");

const sourceFiles = allFiles("src", [".ts", ".tsx"]);
const sourceText = sourceFiles.map((file) => fs.readFileSync(file, "utf8")).join("\n");

const routeFiles = allFiles("src/app", ["page.tsx", "route.ts"]);
const routePatterns = routeFiles.map((file) => {
  let relative = path.relative(path.join(root, "src/app"), path.dirname(file)).replaceAll(path.sep, "/");
  relative = relative === "." ? "" : `/${relative}`;
  const escaped = relative.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\\\[\\\.\\\.\\\.([^\]]+)\\\]/g, ".+").replace(/\\\[([^\]]+)\\\]/g, "[^/]+");
  return new RegExp(`^${escaped || "/"}/?$`);
});
const staticInternalTargets = [];
for (const file of sourceFiles) {
  const source = fs.readFileSync(file, "utf8");
  for (const match of source.matchAll(/(?:href|action)=["'](\/[A-Za-z0-9_./-]+)["']/g)) {
    const target = match[1].split(/[?#]/)[0];
    if (target.startsWith("/_next/")) continue;
    staticInternalTargets.push([path.relative(root, file), target]);
  }
}
const brokenStaticRoutes = staticInternalTargets.filter(([, target]) => !routePatterns.some((rx) => rx.test(target)));
brokenStaticRoutes.length ? fail(`Literal internal links/forms without App Router endpoints: ${brokenStaticRoutes.slice(0, 20).map(([file,target]) => `${file} -> ${target}`).join(", ")}`) : pass(`Literal internal links/forms resolve to App Router endpoints (${staticInternalTargets.length} checked)`);
const noticeAdminPage = read("src/app/admin/notices/page.tsx");
const systemActionsSource = read("src/actions/system.ts");
const adminActionsNoticeSource = read("src/actions/admin.ts");
/saveNoticeTemplateAction/.test(systemActionsSource) && /deleteNoticeTemplateAction/.test(systemActionsSource) && /assignArticleNoticeAction/.test(adminActionsNoticeSource) && /removeArticleNoticeAction/.test(adminActionsNoticeSource) && /Editorial notices/.test(noticeAdminPage) && /\/admin\/notices/.test(adminLayout) ? pass("Editorial notice administration is implemented and reachable") : fail("Editorial notice administration is missing actions, UI, or navigation");
const directCanonicalTaxonomyWrites = sourceFiles.flatMap((file) => { const source = fs.readFileSync(file, "utf8"); return [...source.matchAll(/\.from\(["']article_(?:categories|tags)["']\)[\s\S]{0,180}?\.(?:insert|update|delete)\(/g)].map(() => path.relative(root, file)); });
directCanonicalTaxonomyWrites.length ? fail(`Application source directly mutates canonical taxonomy: ${[...new Set(directCanonicalTaxonomyWrites)].join(", ")}`) : pass("Application source does not directly mutate canonical article taxonomy");
const portugueseUi = /[ÁÉÍÓÚÂÊÔÃÕÇáéíóúâêôãõç]|\b(?:artigo|artigos|usuário|usuários|categoria|categorias|salvar|editar|excluir|pesquisar|entrar|sair|página|páginas|revisão|revisões|publicado|rascunho|nenhum|nenhuma|mensagem|configurações|administração|discussão|histórico|notificações|senha|privacidade|denúncia|denúncias|aprovar|rejeitar|conteúdo|resumo|título)\b/i;
const portugueseHits = [];
for (const file of sourceFiles) {
  const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
  lines.forEach((line, index) => { if (portugueseUi.test(line)) portugueseHits.push(`${path.relative(root, file)}:${index + 1}`); });
}
portugueseHits.length ? fail(`Portuguese UI/source text remains: ${portugueseHits.slice(0, 20).join(", ")}`) : pass("English-only source sweep found no Portuguese UI strings");

const explicitAny = [];
for (const file of sourceFiles) {
  const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
  lines.forEach((line, index) => { if (/:\s*any\b|\bas\s+any\b|<[^>]*\bany\b[^>]*>/.test(line)) explicitAny.push(`${path.relative(root, file)}:${index + 1}`); });
}
explicitAny.length ? fail(`Explicit any escapes remain: ${explicitAny.slice(0, 20).join(", ")}`) : pass("No explicit any escapes remain in TS/TSX source");

const importErrors = [];
for (const file of sourceFiles) {
  const text = fs.readFileSync(file, "utf8");
  for (const match of text.matchAll(/from\s+["']@\/([^"']+)["']/g)) {
    const relative = match[1];
    const candidates = [path.join(root, "src", `${relative}.ts`), path.join(root, "src", `${relative}.tsx`), path.join(root, "src", relative, "index.ts"), path.join(root, "src", relative, "index.tsx")];
    if (!candidates.some(fs.existsSync)) importErrors.push(`${path.relative(root, file)} -> @/${relative}`);
  }
}
importErrors.length ? fail(`Broken local imports: ${importErrors.slice(0, 20).join(", ")}`) : pass("All local @/ imports resolve to source files");

const publicProfileViolations = sourceFiles.filter((file) => {
  const rel = path.relative(root, file).replaceAll("\\", "/");
  if (!rel.startsWith("src/app/")) return false;
  if (rel.startsWith("src/app/admin/") || rel.startsWith("src/app/dashboard/") || rel.startsWith("src/app/mfa/") || rel.startsWith("src/app/suspended/")) return false;
  return /\.from\(["']profiles["']\)/.test(fs.readFileSync(file, "utf8"));
});
publicProfileViolations.length ? fail(`Public routes query private profiles: ${publicProfileViolations.map((file) => path.relative(root, file)).join(", ")}`) : pass("Public routes use the public profile projection instead of private profiles");

const allSql = ["001_initial.sql", "002_wiki_update.sql", "003_production_release.sql"].map((name) => read(`supabase/migrations/${name}`)).join("\n");
const rpcNames = new Set([...sourceText.matchAll(/\.rpc\(["']([^"']+)/g)].map((match) => match[1]));
const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const missingRpcs = [...rpcNames].filter((name) => !new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${escapeRegExp(name)}\\s*\\(`, "i").test(allSql));
missingRpcs.length ? fail(`RPCs used by the app are missing from migrations: ${missingRpcs.join(", ")}`) : pass(`All ${rpcNames.size} application RPCs are defined in shipped migrations`);

const serverActions = allFiles("src/actions", [".ts"]).map((file) => fs.readFileSync(file, "utf8")).join("\n");
/formData\.get\(["'](?:cover_file|video_file|file)["']\)/i.test(serverActions) ? fail("A Server Action still reads a media file payload") : pass("Server Actions do not receive image/video file bodies");
const directUpload = read("src/components/DirectMediaUpload.tsx");
/\.storage\.from\(["']zionxyos-media["']\)\.upload\(/.test(directUpload) ? pass("Media uploads go directly from browser to Supabase Storage") : fail("Direct browser-to-Supabase media upload was not found");
/file\.slice\(0,32\)|file\.slice\(0,\s*32\)/.test(directUpload) ? pass("Client media picker performs signature sniffing") : warn("Client media signature check was not detected");
/EXTENSION:Record<string,string>/.test(directUpload) && /crypto\.randomUUID\(\)\}\.\$\{ext\}/.test(directUpload) ? pass("Browser upload paths use canonical extensions derived from MIME type") : fail("Browser upload paths preserve untrusted file extensions");
/storage\.extension\(name\)/i.test(migration) && /metadata->>'mimetype'/i.test(migration) ? pass("Storage RLS cross-checks object extension and declared MIME type") : fail("Storage upload RLS does not cross-check extension and MIME type");

const secretLeaks = [];
for (const file of [...sourceFiles, path.join(root, ".env.example")]) {
  const text = fs.readFileSync(file, "utf8");
  if (/sb_secret_|service[_-]?role\s*[=:]\s*["'][A-Za-z0-9]/i.test(text)) secretLeaks.push(path.relative(root, file));
}
secretLeaks.length ? fail(`Possible privileged Supabase secret committed in: ${secretLeaks.join(", ")}`) : pass("No Supabase service-role/secret key pattern is committed");
const dangerousSourcePrimitives = /dangerouslySetInnerHTML|\beval\s*\(|\bnew\s+Function\s*\(/;
dangerousSourcePrimitives.test(sourceText) ? fail("Application source contains a dangerous dynamic HTML/code execution primitive") : pass("Application source contains no dangerouslySetInnerHTML/eval/new Function usage");
const clientServerViolations = [];
for (const file of sourceFiles) {
  const text = fs.readFileSync(file, "utf8");
  if (!/^\s*["']use client["'];/m.test(text)) continue;
  for (const serverOnly of ["@/lib/supabase/server", "@/lib/auth", "@/lib/media-server", "next/headers", "next/cache"]) {
    if (text.includes(serverOnly)) clientServerViolations.push(`${path.relative(root, file)} -> ${serverOnly}`);
  }
}
clientServerViolations.length ? fail(`Client modules import server-only code: ${clientServerViolations.join(", ")}`) : pass("Client modules do not import known server-only modules");

const gitignoreSource = read(".gitignore");
const localArtifactIgnoreRules = [
  ["node_modules", /(^|\n)node_modules\/($|\n)/],
  [".next", /(^|\n)\.next\/($|\n)/],
  [".env", /(^|\n)\.env($|\n)/],
  [".env.local", /(^|\n)\.env\.local($|\n)/],
  [".env.*.local", /(^|\n)\.env\.\*\.local($|\n)/],
  ["*.tsbuildinfo", /(^|\n)\*\.tsbuildinfo($|\n)/],
];
const missingArtifactIgnores = localArtifactIgnoreRules.filter(([, pattern]) => !pattern.test(gitignoreSource)).map(([name]) => name);
missingArtifactIgnores.length ? fail(`Generated/private working artifacts are not fully ignored by source control: ${missingArtifactIgnores.join(", ")}`) : pass("Generated/private working artifacts are source-control ignored and may exist during dependency-complete validation");

const css = read("src/app/globals.css");
const cssWithoutComments = css.replace(/\/\*[\s\S]*?\*\//g, "");
const cssOpen = (cssWithoutComments.match(/\{/g) || []).length;
const cssClose = (cssWithoutComments.match(/\}/g) || []).length;
cssOpen === cssClose ? pass("CSS block braces are balanced") : fail(`CSS block braces are unbalanced: ${cssOpen} opening / ${cssClose} closing`);
/\b\d+(?:\.\d+)?\.[A-Za-z_-][\w-]*\s*\{/.test(cssWithoutComments) ? fail("CSS contains a suspicious numeric/property-selector corruption") : pass("CSS contains no obvious numeric selector corruption");
const cssClasses = new Set([...css.matchAll(/\.([A-Za-z_][\w-]*)/g)].map((match) => match[1]));
const literalClasses = new Set();
for (const file of sourceFiles) {
  const text = fs.readFileSync(file, "utf8");
  for (const match of text.matchAll(/className=["']([^"']+)["']/g)) for (const token of match[1].split(/\s+/)) if (token) literalClasses.add(token);
}
const unstyled = [...literalClasses].filter((name) => !cssClasses.has(name)).sort();
unstyled.length ? fail(`Literal UI classes without CSS rules: ${unstyled.slice(0, 25).join(", ")}`) : pass(`All ${literalClasses.size} literal UI classes have stylesheet rules`);

const legalVersion = "2026-09-09-v1";
const legalFiles = ["src/app/legal/terms/page.tsx", "src/app/legal/privacy/page.tsx", "src/app/legal/guidelines/page.tsx"];
legalFiles.every((file) => read(file).includes(legalVersion)) && migration.includes(legalVersion) ? pass(`Legal policy version ${legalVersion} is consistent across UI and database`) : fail("Legal policy versions are inconsistent");

const dangerousRuntime = /\beval\s*\(|new\s+Function\s*\(|child_process|execSync\(|spawn\(|writeFileSync\(/;
const updateSource = read("src/actions/system.ts") + read("src/app/admin/system/page.tsx");
dangerousRuntime.test(updateSource) ? fail("System updater contains arbitrary local code execution/file-write behavior") : pass("System updater does not execute uploaded code or rewrite the running application");
/VERCEL_DEPLOY_HOOK_URL/.test(updateSource) && /release_manifest_url/.test(updateSource) ? pass("Updater uses a server-side Vercel Deploy Hook and trusted release manifest model") : fail("Expected safe updater integration is missing");

const permissionSource = read("src/lib/article-permissions.ts") + read("src/actions/articles.ts") + read("src/actions/admin.ts") + read("src/app/article/[slug]/page.tsx") + read("src/app/dashboard/articles/[id]/edit/page.tsx") + read("src/app/admin/review/[id]/page.tsx") + read("src/app/admin/review/[id]/edit/page.tsx");
/can_edit_article/.test(permissionSource) && /canEditArticle/.test(permissionSource) && /Page protection does not permit/.test(permissionSource) ? pass("Application edit/review UX uses the same database page-protection capability") : fail("Application edit/review UX is disconnected from database page protection");
const editorSource = read("src/lib/editor.ts") + read("src/components/ArticleForm.tsx");
/getPublicSiteSettings/.test(read("src/lib/editor.ts")) && !/getAllSiteSettings/.test(read("src/lib/editor.ts")) ? pass("Contributor editor reads only public site settings") : fail("Contributor editor reads private system settings");
/name="category_ids"/.test(editorSource) && /name="tag_ids"/.test(editorSource) && !/name="(?:categories|tags)"/.test(read("src/components/ArticleForm.tsx")) ? pass("Article editor uses controlled taxonomy IDs instead of free-form categories/tags") : fail("Article editor still exposes free-form taxonomy fields");

const taxonomyPage = read("src/app/admin/taxonomy/page.tsx");
const taxonomyActions = read("src/actions/taxonomy.ts");
/CategoryTreeNode/.test(taxonomyPage) && /taxonomy-tree-children/.test(taxonomyPage) && /<details className="taxonomy-admin-item"/.test(taxonomyPage) ? pass("Sysadmin category administration renders an expandable hierarchy") : fail("Admin category management is not an expandable hierarchy");
/mergeCategoryAction/.test(taxonomyPage) && /sysadmin_merge_category/.test(taxonomyActions) && /A category cannot be merged into one of its descendants/.test(migration) && /taxonomy\.category_merged/.test(migration) ? pass("Category merge is atomic, cycle-safe, audited, and exposed only through sysadmin taxonomy controls") : fail("Category merge safety/workflow is incomplete");
const mediaAdminPage = read("src/app/admin/media/page.tsx");
/sysadmin_media_usage_counts/.test(mediaAdminPage) && /article_uses/.test(mediaAdminPage) && /revision_uses/.test(mediaAdminPage) && /In use — protected/.test(mediaAdminPage) ? pass("Media Library shows article/revision usage and protects referenced assets in the UI") : fail("Media Library usage visibility/protection is incomplete");
const communityActions = read("src/actions/community.ts");
/validUuid/.test(communityActions) && /eq\("article_id", article\.id\)/.test(communityActions) && /rpc\("is_valid_report_target"/.test(communityActions) && /reported target is no longer publicly available/.test(communityActions) ? pass("Community actions validate UUID targets, discussion parents, and report target existence") : fail("Community action target validation is incomplete");
/create or replace function public\.is_valid_report_target/.test(migration) && /public\.is_valid_report_target\(target_type,target_id\)/.test(migration) ? pass("Database report policy independently validates public target existence") : fail("Direct report inserts can target nonexistent or private objects");
/create or replace function public\.can_post_discussion[\s\S]*?a\.status='published'[\s\S]*?a\.deleted_at is null[\s\S]*?p\.article_id=article_uuid[\s\S]*?p\.removed_at is null/i.test(migration) && /create policy "discussion_active_insert"[\s\S]*?public\.can_post_discussion\(article_id,parent_id,auth\.uid\(\)\)/i.test(migration) ? pass("Database discussion policy rejects private/retired article targets and invalid cross-article reply parents") : fail("Direct discussion inserts can bypass public-article or parent-thread validation");
/drop policy if exists "watchlist_own_all"[\s\S]*?create policy "watchlist_own_read_v03"[\s\S]*?create policy "watchlist_own_insert_v03"[\s\S]*?a\.status='published'[\s\S]*?a\.deleted_at is null[\s\S]*?create policy "watchlist_own_delete_v03"/i.test(finalHardening) ? pass("Watchlist RLS is split into own-read/delete plus public-article-only insert") : fail("Watchlist RLS still permits overly broad or private-target writes");
/Existing removal metadata is immutable; restore the post before removing it again/.test(finalHardening) && /removed_by must be null when a post is visible/.test(finalHardening) ? pass("Discussion moderation metadata has consistent remove/restore invariants") : fail("Discussion removal metadata can be rewritten into inconsistent states");
/Invalid administrative report state/.test(finalHardening) && /new\.reviewed_by := auth\.uid\(\)/.test(finalHardening) && /new\.reviewed_at := now\(\)/.test(finalHardening) ? pass("Report workflow actor and resolution timestamps are database-controlled") : fail("Report administrative metadata can be client-forged");

/drop policy if exists "notifications_own_read"[\s\S]*?create policy "notifications_own_read"[\s\S]*?using \(user_id = auth\.uid\(\)\)/i.test(finalHardening) ? pass("Notifications are readable only by their owner") : fail("Legacy notification read policy still exposes another user's notifications to a privileged raw-role bypass");
/drop policy if exists "versions_author_or_admin_read"[\s\S]*?create policy "versions_author_or_admin_read"[\s\S]*?is_sysadmin_mfa\(auth\.uid\(\)\)[\s\S]*?a\.author_id = auth\.uid\(\)/i.test(finalHardening) ? pass("Legacy article-version history requires ownership or sysadmin MFA") : fail("Legacy article-version history retains a raw sysadmin read bypass");
const authActions = read("src/actions/auth.ts");
/consumeRateLimit\("password_reset",5,3600\)/.test(authActions) && /password_reset/.test(migration) ? pass("Password recovery is anonymously rate-limited") : fail("Password recovery lacks a dedicated anonymous rate limit");
const securityPage = read("src/app/dashboard/security/page.tsx");
/changePasswordAction/.test(securityPage) && /changeEmailAction/.test(securityPage) && /signOutOtherSessionsAction/.test(securityPage) && /dashboard\/security/.test(read("src/app/dashboard/layout.tsx")) ? pass("Account security page exposes password, email, and session controls") : fail("Account security controls are incomplete or unreachable");
/current_password:\s*currentPassword/.test(authActions) && /scope:\s*["']others["']/.test(authActions) ? pass("Credential changes re-check the current password and other-session logout preserves the current session") : fail("Account security actions lack current-password/session-scope safeguards");
const utilsSource = read("src/lib/utils.ts");
const callbackSource = read("src/app/auth/callback/route.ts");
/safeReturnPath/.test(callbackSource) && /candidate\.includes\(["']\\\\["']\)/.test(utilsSource) && /resolved\.origin===base\.origin/.test(utilsSource) ? pass("Authentication and notification return paths reject protocol-relative/backslash cross-origin redirects") : fail("Internal return-path sanitization can be bypassed into a cross-origin redirect");
/!context\.userView/.test(read("src/app/dashboard/security/page.tsx")) ? pass("Sysadmin regular-user test mode hides the privileged MFA shortcut") : fail("Regular-user test mode still exposes the administrative MFA shortcut");
const maintenanceProxy = read("src/lib/supabase/proxy.ts");
/path===?["']\/api\/health["']|path===?["']\/api\/health["']/.test(maintenanceProxy) && /robots\.txt/.test(maintenanceProxy) && /sitemap\.xml/.test(maintenanceProxy) ? pass("Maintenance mode keeps health, robots, and sitemap endpoints reachable") : fail("Maintenance mode blocks operational or crawler metadata endpoints");
const tsconfig = JSON.parse(read("tsconfig.json"));
tsconfig.compilerOptions?.tsBuildInfoFile === ".next/cache/tsconfig.tsbuildinfo" && /\*\.tsbuildinfo/.test(read(".gitignore")) ? pass("TypeScript incremental metadata is kept out of the release root") : fail("TypeScript build metadata can dirty the release root");
const packageSource = read("scripts/package-release.mjs");
/unzip/.test(packageSource) && /sha256/i.test(packageSource) && /node_modules/.test(packageSource) && /\.env/.test(packageSource) ? pass("Release packager validates ZIP integrity, emits SHA-256, and excludes private/generated artifacts") : fail("Release packaging script lacks integrity/checksum/exclusion safeguards");
!/Refusing to package private\/generated root artifact/.test(packageSource) && /Excluding local\/private artifacts from archive/.test(packageSource) ? pass("Release packager supports dependency-complete local validation while still excluding local/private artifacts") : fail("Release packager still conflicts with dependency-complete validation artifacts");
const finalizerSource = read("scripts/finalize-release.mjs");
finalizerSource.includes("npm") && finalizerSource.includes("run") && finalizerSource.includes("preflight") && finalizerSource.includes("zionxyos-v0.3-final.zip") && finalizerSource.includes("FINAL RELEASE GATE PASSED") ? pass("Final release packaging is gated behind dependency-complete preflight") : fail("Final archive can be produced without the full preflight gate");
/Number\(process\.versions\.node/.test(finalizerSource) && /nodeMajor !== 24/.test(finalizerSource) && /package-lock\.json/.test(finalizerSource) && /\["ci", "--no-audit", "--no-fund"\]/.test(finalizerSource) && /\["ls", "--depth=0"\]/.test(finalizerSource) ? pass("Finalizer enforces Node 24, a reproducible lockfile, clean-install support, and dependency-tree verification") : fail("Finalizer lacks Node 24, package-lock, npm ci, or npm ls enforcement");
/confirmation!==["']DEPLOY["']/.test(updateSource) && /name=["']deploy_confirmation["']/.test(updateSource) ? pass("Production deploy trigger requires an explicit typed confirmation in addition to sysadmin MFA") : fail("Production deploy action lacks an explicit confirmation gate");
/Add custom field/.test(read("src/components/ArticleForm.tsx")) && /infobox_json/.test(read("src/components/ArticleForm.tsx")) ? pass("Dynamic infobox builder supports schema fields plus custom fields") : fail("Structured infobox builder is incomplete");
/getPublicUrl\(asset\.object_path\)/.test(read("src/lib/media-server.ts")) && /resolveStoredMediaUrls/.test(read("src/app/article/[slug]/page.tsx")) ? pass("Server rendering reconstructs managed-media URLs from bucket/object path") : fail("Published managed media still depends on client-written public_url metadata");
/trustedManifestUrl/.test(updateSource) && /public HTTPS host/.test(updateSource) ? pass("Release manifest fetch rejects local/private hostnames") : fail("Release manifest fetch lacks local/private-host SSRF guard");
/::ffff:169\.254/.test(updateSource) && /::ffff:172/.test(updateSource) && /::ffff:100/.test(updateSource) ? pass("Release manifest guard covers IPv4-mapped IPv6 link-local, private, and CGNAT ranges") : fail("Release manifest guard misses IPv4-mapped IPv6 private/link-local ranges");
/sysadmin_set_settings/.test(updateSource) && /Object\.fromEntries\(values\)/.test(updateSource) && /create or replace function public\.sysadmin_set_settings/.test(migration) && /for setting_key, setting_value in select key, value from jsonb_each\(settings_payload\)/.test(migration) && /revoke all on function public\.sysadmin_set_setting\(text,jsonb\) from public, anon, authenticated/.test(migration) ? pass("System settings save atomically through one MFA RPC and the single-key helper is not browser-callable") : fail("System settings can partially apply or expose the single-key mutation helper");
/redirect:\"error\"/.test(updateSource) && /must not contain credentials/.test(updateSource) && /standard HTTPS port/.test(updateSource) ? pass("Update fetches reject redirect pivots, URL credentials, and nonstandard manifest ports") : fail("Updater redirect/URL hardening is incomplete");
/api\.vercel\.com/.test(updateSource) && /\/v1\/integrations\/deploy\//.test(updateSource) ? pass("Deploy trigger validates the expected Vercel Deploy Hook endpoint") : fail("Deploy trigger accepts an unrestricted hook destination");

/setCoverUrl\(asset\?\.public_url \|\| ""\)/.test(sourceText) && /setVideoUrl\(asset\?\.public_url \|\| ""\)/.test(sourceText) ? pass("Clearing a managed-media selection also clears its stale URL") : fail("Clearing a managed-media selection can leave a stale Storage URL without its media FK");
const noticeCss = read("src/app/globals.css");
["article-notice","notice-info","notice-warning","notice-maintenance","notice-quality"].every((name) => noticeCss.includes(`.${name}`)) ? pass("All reader-facing editorial notice variants have explicit CSS styling") : fail("One or more editorial notice variants render without explicit CSS styling");
/articles_content_size_v03[\s\S]*?char_length\(content\) <= 500000[\s\S]*?revisions_content_size_v03[\s\S]*?char_length\(content\) <= 500000/i.test(migration) && /articles_infobox_shape_v03[\s\S]*?jsonb_typeof\(infobox\) = 'object'[\s\S]*?revisions_infobox_shape_v03/i.test(migration) ? pass("Article/revision payload size and infobox shape are bounded at the database boundary") : fail("Large or malformed article/revision payloads are not bounded in the database");
/enforce_revision_taxonomy_limit[\s\S]*?pg_advisory_xact_lock[\s\S]*?category_id = \(\(to_jsonb\(new\)->>'category_id'\)::uuid\)[\s\S]*?tag_id = \(\(to_jsonb\(new\)->>'tag_id'\)::uuid\)[\s\S]*?item_count >= 100/i.test(migration) && /selected_category_count > 100/i.test(migration) && /selected_tag_count > 100/i.test(migration) ? pass("Normalized revision taxonomy is capped under concurrency, tolerates duplicate upserts, and is rechecked at approval") : fail("Direct clients can attach unbounded taxonomy to a revision or duplicate upserts can trip the cap");
const registrationActions = read("src/actions/auth.ts");
/RESERVED_USERNAMES/.test(registrationActions) && /public_profiles/.test(registrationActions) && /already in use/.test(registrationActions) ? pass("Registration rejects reserved/taken usernames before creating the Auth account") : fail("Registration does not preflight reserved and existing usernames");
/exception when unique_violation/.test(migration) && /fallback_username/.test(migration) ? pass("Auth profile bootstrap handles simultaneous username races without aborting signup") : fail("Auth profile bootstrap can fail on a concurrent duplicate username");
/fallback_username text := 'user_' \|\| left\(replace\(new\.id::text,'-',''\), 18\)/.test(migration) ? pass("Signup fallback username remains inside the profile username character/length constraint") : fail("Signup fallback username can violate the profile username constraint");
/handle_new_user[\s\S]*?registration_enabled[\s\S]*?Registration is currently disabled/i.test(migration.slice(migration.lastIndexOf("Signup race hardening."))) ? pass("Database Auth bootstrap enforces the registration feature switch against direct Supabase signups") : fail("Direct Supabase Auth signup can bypass registration_enabled");
/pg_advisory_xact_lock/.test(migration) && /hashtextextended\(action_name/.test(migration) ? pass("Rate-limit buckets serialize concurrent count/insert operations") : fail("Rate-limit count/insert operations can race under concurrency");
const proxySource = read("src/lib/supabase/proxy.ts");
const rootProxySource = read("proxy.ts");
/api\/health/.test(rootProxySource) && /robots\.txt/.test(rootProxySource) && /sitemap\.xml/.test(rootProxySource) ? pass("Operational health and metadata endpoints bypass auth Proxy refresh work") : fail("Health/robots/sitemap are still coupled to auth Proxy refresh before their route handlers run");
const supabaseServerSource = read("src/lib/supabase/server.ts");
/setAll\(list,headers\)/.test(proxySource) && /Object\.entries\(\(headers\|\|\{\}\)/.test(proxySource) && /typeof value==="string"/.test(proxySource) && /cache-control/.test(proxySource) && /expires/.test(proxySource) && /pragma/.test(proxySource) && /carryAuthState/.test(proxySource) && /setAll\(cookiesToSet, _headers\)/.test(supabaseServerSource) ? pass("Supabase SSR token-refresh cache headers are preserved through Proxy responses and maintenance redirects") : fail("Supabase SSR setAll cache headers can be dropped, risking cached authenticated responses");
/select\(["']role,suspended["']\)/.test(proxySource) && /suspended===false/.test(proxySource) ? pass("Suspended staff cannot bypass maintenance mode") : fail("Maintenance-mode staff bypass ignores suspension state");
/Invalid legal contact email/.test(migration) && /URL must be a non-empty HTTPS URL/.test(migration) ? pass("System-setting RPC validates contact email and HTTPS URL shape") : fail("System-setting RPC accepts malformed contact email or URL values");
/left\(trim\(search_text\),200\)/.test(migration) && /\[1:200\]/.test(migration) && /left\(trim\(wanted\.value\),160\)/.test(migration) && /targets\.size >= 200/.test(read("src/lib/wiki.ts")) ? pass("Public wiki search/link RPC inputs are bounded on both application and database paths") : fail("Public wiki helper inputs remain unbounded");
/index:false/.test(read("src/app/search/page.tsx")) && /slice\(0,200\)/.test(read("src/app/search/page.tsx")) ? pass("Search pages are noindex and cap public query length") : fail("Search route lacks crawler or query-length controls");
const wikiSource = read("src/lib/wiki.ts");
/safeReferenceUrl/.test(wikiSource) && /url\.protocol === "https:" \|\| url\.protocol === "http:"/.test(wikiSource) && /url: safeReferenceUrl\(fields\.url\)/.test(wikiSource) ? pass("Citation reference URLs are constrained to HTTP(S)") : fail("Citation reference rendering can receive an unsafe URL scheme");
const mediaUrlSource = read("src/lib/media-url.ts");
/safeMediaUrl/.test(mediaUrlSource) && /url\.username \|\| url\.password/.test(mediaUrlSource) && /requireMediaUrl/.test(read("src/actions/articles.ts")) && /requireMediaUrl/.test(read("src/actions/admin.ts")) && /safeMediaUrl/.test(read("src/lib/video.ts")) && /safeMediaUrl/.test(read("src/components/WikiArticle.tsx")) ? pass("External media URLs are centrally constrained to credential-free HTTPS before storage and rendering") : fail("External media URL validation is inconsistent across edit/review/render paths");
migration.includes("cover_image_url !~ '^https://[^/@[:space:]]+") && migration.includes("video_url !~ '^https://[^/@[:space:]]+") ? pass("Database revision/approval boundaries reject media URLs with embedded credentials") : fail("Database media URL checks allow embedded URL credentials");
const publicMetadataSources = [read("src/app/article/[slug]/page.tsx"), read("src/app/categories/[name]/page.tsx"), read("src/app/u/[username]/page.tsx")];
publicMetadataSources.every((source) => /generateMetadata/.test(source) && /alternates:\s*\{\s*canonical:/.test(source)) ? pass("Article, category, and public-profile detail routes emit canonical dynamic metadata") : fail("A major public detail route lacks canonical dynamic metadata");
/url\.username \|\| url\.password/.test(wikiSource) ? pass("Citation URLs reject embedded credentials") : fail("Citation URLs can retain embedded credentials");
const supabaseConfigSource = read("src/lib/supabase/config.ts");
const supabaseClientSources = [read("src/lib/supabase/server.ts"), read("src/lib/supabase/client.ts"), read("src/lib/supabase/proxy.ts")];
/NEXT_PUBLIC_SUPABASE_URL is required/.test(supabaseConfigSource) && /PUBLISHABLE_KEY is missing or still uses a placeholder/.test(supabaseConfigSource) && /must not contain credentials/.test(supabaseConfigSource) && /must use HTTPS outside local development/.test(supabaseConfigSource) && supabaseClientSources.every((source) => /getSupabasePublicConfig/.test(source) && !/process\.env\.NEXT_PUBLIC_SUPABASE_(?:URL|PUBLISHABLE_KEY)/.test(source)) ? pass("Supabase public URL/key configuration is centrally validated before browser/server/proxy client creation") : fail("Supabase clients can be created from missing, placeholder, credential-bearing, or insecure public configuration");
const authCallbackSource = read("src/app/auth/callback/route.ts");
/authRedirect/.test(authCallbackSource) && /Cache-Control/.test(authCallbackSource) && /private, no-store/.test(authCallbackSource) && /Pragma/.test(authCallbackSource) && /Expires/.test(authCallbackSource) ? pass("Auth callback redirects are explicitly non-cacheable while exchanging session cookies") : fail("Auth callback redirects can omit explicit no-store headers while setting a session");
const siteUrlSource = read("src/lib/site-url.ts");
/NEXT_PUBLIC_SITE_URL is required for a production Zionxyos build/.test(siteUrlSource) && /must use HTTPS outside localhost/.test(siteUrlSource) && /must not contain credentials/.test(siteUrlSource) && /getCanonicalSiteUrl/.test(read("src/app/auth/callback/route.ts")) && /getCanonicalSiteUrl/.test(read("src/actions/auth.ts")) && /getCanonicalSiteUrl/.test(read("src/app/sitemap.ts")) && /getCanonicalSiteUrl/.test(read("src/app/robots.ts")) ? pass("Canonical public/auth URLs share a validated HTTPS site-origin helper") : fail("Public/auth URL generation can silently use an invalid production origin");
const rateLimitSource = read("src/lib/rate-limit.ts");
/RATE_LIMIT_SALT must be a non-placeholder secret/.test(rateLimitSource) && /configured\.length < 24/.test(rateLimitSource) && /process\.env\.NODE_ENV === "production"/.test(rateLimitSource) ? pass("Anonymous rate limiting fails closed on a weak production salt") : fail("Anonymous production rate limiting can silently use a predictable salt");
/NODE_ENV === "production"/.test(siteUrlSource) && /VERCEL_ENV === "production"/.test(siteUrlSource) && /cannot use localhost in a production deployment/.test(siteUrlSource) ? pass("Canonical site URL rejects localhost in production, including non-Vercel deployments") : fail("A production deployment can use a localhost canonical origin");
/hostname\.replace\(\/\^\\\[\|\\\]\$\/g/.test(siteUrlSource) && /hostname\.replace\(\/\^\\\[\|\\\]\$\/g/.test(mediaUrlSource) ? pass("IPv6 loopback host normalization is consistent in canonical/media URL validation") : fail("IPv6 loopback URLs can bypass local-host detection");
const legalAcceptPage = read("src/app/legal/accept/page.tsx");
/name="legal_acceptance"/.test(legalAcceptPage) && /acceptLegalAction\(f:FormData\)/.test(registrationActions) && /f\.get\("legal_acceptance"\)!=="on"/.test(registrationActions) ? pass("Existing-account legal re-consent requires an explicit submitted acceptance") : fail("Legal re-consent can be recorded without the acceptance checkbox reaching the server action");

const homeSource = read("src/app/page.tsx");
const searchSource = read("src/app/search/page.tsx");
/getPublicSiteSettings/.test(homeSource) && /settings\.siteName/.test(homeSource) && /settings\.tagline/.test(homeSource) && /canCreate/.test(homeSource) && /registrationEnabled/.test(homeSource) ? pass("Homepage branding and contribution links follow live site settings/account capability") : fail("Homepage exposes stale branding or ungated contribution links");
/getPublicSiteSettings/.test(searchSource) && /getAuthContext/.test(searchSource) && /canCreate/.test(searchSource) && /registrationEnabled/.test(searchSource) && !/Signed-in contributors may/.test(searchSource) ? pass("Empty-search contribution CTA follows account and feature-switch state") : fail("Search empty-state exposes an unconditional contribution CTA");

const mfaPanelSource = read("src/components/MfaPanel.tsx");
/listFactors/.test(mfaPanelSource) && /status !== ["']verified["']/.test(mfaPanelSource) && /mfa\.unenroll/.test(mfaPanelSource) && /mfa\.enroll/.test(mfaPanelSource) ? pass("MFA enrollment clears stale unverified TOTP factors before creating a replacement") : fail("Repeated MFA enrollment can accumulate stale unverified factors");

/required_infobox_complete[\s\S]*?jsonb_array_elements[\s\S]*?required/.test(migration) && /Complete all required infobox fields before review submission/.test(migration) && /A required infobox field is missing/.test(migration) ? pass("Required Article Type infobox fields are enforced at database submission and approval boundaries") : fail("Required infobox fields can be bypassed outside the browser UI");

/discussion_public_read_v03[\s\S]*?removed_at is null[\s\S]*?a\.status='published'[\s\S]*?a\.deleted_at is null[\s\S]*?discussion_authenticated_read_v03[\s\S]*?is_admin_mfa/.test(finalHardening) ? pass("Retired/private article discussions are hidden from direct public reads while MFA staff retain moderation access") : fail("Discussion SELECT RLS can expose posts from retired/private pages");
/article_notices_public_read_v03[\s\S]*?a\.status='published'[\s\S]*?a\.deleted_at is null[\s\S]*?article_notices_authenticated_read_v03[\s\S]*?is_admin_mfa/.test(finalHardening) ? pass("Editorial notice assignments disappear from public reads when the canonical page is retired") : fail("Editorial notice relation reads ignore canonical page retirement");
finalHardening.includes("audit_notice_template_change") && finalHardening.includes("notice_templates_audit_v03") && finalHardening.includes("audit_article_notice_change") && finalHardening.includes("article_notices_audit_v03") && finalHardening.includes("notice_template.'||lower(tg_op)") && finalHardening.includes("article_notice.'||lower(tg_op)") ? pass("Editorial notice template/assignment mutations are recorded in the administrative audit log") : fail("Editorial notice mutations are not fully audit logged");
finalHardening.includes("audit_report_workflow_change") && finalHardening.includes("reports_audit_workflow_v03") && finalHardening.includes("report.workflow_update") && finalHardening.includes("audit_discussion_moderation_change") && finalHardening.includes("discussion_posts_audit_moderation_v03") && finalHardening.includes("discussion.removed") ? pass("Report workflow and discussion moderation mutations are recorded in the administrative audit log") : fail("Report/discussion administrative mutations are not fully audit logged");

/create or replace function public\.is_admin_mfa[\s\S]*?is_active_user\(uid\)[\s\S]*?has_current_legal_acceptance\(uid\)/i.test(finalHardening) ? pass("Admin MFA capability also requires an active account and current legal consent") : fail("Suspended/banned or legally stale Admin sessions can retain direct database privileges");
/create or replace function public\.is_sysadmin_mfa[\s\S]*?is_active_user\(uid\)[\s\S]*?has_current_legal_acceptance\(uid\)/i.test(finalHardening) ? pass("Sysadmin MFA capability also requires active account state and current legal consent") : fail("Inactive or legally stale Sysadmin sessions can retain direct database privileges");

const articlePermissionSource = read("src/lib/article-permissions.ts");
/regularUserView/.test(articlePermissionSource) && /protection_level === ["']open["']/.test(articlePermissionSource) && /protected_until/.test(articlePermissionSource) && /regularUserView:c\.userView/.test(read("src/actions/articles.ts")) ? pass("Sysadmin regular-user test mode cannot exercise privileged page-protection edits") : fail("Regular-user test mode still inherits sysadmin page-edit capability");
const rootLayoutSource = read("src/app/layout.tsx");
/audience===["']staff["'][\s\S]*?!context\.userView/.test(rootLayoutSource) ? pass("Regular-user test mode hides staff-only announcements") : fail("Regular-user test mode leaks staff-only announcement UI");

(/create or replace function public\.sysadmin_set_user_role[\s\S]*?is_sysadmin_mfa\(auth\.uid\(\)\)[\s\S]*?requested_role not in \('user','admin'\)[\s\S]*?target_role='sysadmin'/i.test(migration) && /update public\.profiles set role=requested_role where id=target_uid/i.test(migration) && !/requested_role::public\.user_role/i.test(migration)) ? pass("Role assignment is centralized in a Sysadmin+MFA RPC and writes the v0.3 text role safely") : fail("Role assignment RPC has incomplete protection or an obsolete enum cast");
/revoke update \(role, suspended\) on public\.profiles from authenticated/i.test(finalHardening) && /create policy "profiles_self_update"[\s\S]*?id=auth\.uid\(\)[\s\S]*?is_active_user/i.test(finalHardening) ? pass("Browser roles cannot directly mutate privileged profile role/suspension columns") : fail("Privileged profile columns remain directly browser-writable");
const adminRoleSource = read("src/actions/admin.ts");
/sysadmin_set_user_role/.test(adminRoleSource) && !/from\(["']profiles["']\)\.update\(\{ role \}/.test(adminRoleSource) ? pass("Administration role changes use the protected RPC instead of direct profile UPDATE") : fail("Administration still changes roles through direct profile UPDATE");

(/enforce_announcement_integrity/i.test(finalHardening) && /new\.created_by := auth\.uid\(\)/i.test(finalHardening) && /Announcement creator metadata is immutable/i.test(finalHardening) && /Announcement expiry must be after its start time/i.test(finalHardening)) ? pass("Announcements bind immutable creator metadata and validate their time window in the database") : fail("Announcement metadata/time-window integrity can be bypassed through PostgREST");
/announcements_sysadmin_insert_v03[\s\S]*?created_by=auth\.uid\(\)[\s\S]*?announcements_sysadmin_update_v03[\s\S]*?is_sysadmin_mfa[\s\S]*?announcements_sysadmin_delete_v03/i.test(finalHardening) ? pass("Announcement write RLS is operation-specific and Sysadmin+MFA protected") : fail("Announcement write RLS is overly broad or fails to bind the creator");
/audit_announcement_change[\s\S]*?announcements_audit_v03/i.test(finalHardening) && /announcement\.\x27\|\|lower\(tg_op\)/i.test(finalHardening) ? pass("Announcement mutations are recorded in the administrative audit trail") : fail("Announcement mutations are not audit-logged");

(/enforce_notice_template_integrity/i.test(finalHardening) && /new\.created_by := auth\.uid\(\)/i.test(finalHardening) && /Notice template creator metadata is immutable/i.test(finalHardening)) ? pass("Notice-template creator metadata is database-bound and immutable") : fail("Notice-template creator metadata can be forged through direct writes");
/notice_templates_sysadmin_insert_v03[\s\S]*?created_by=auth\.uid\(\)[\s\S]*?notice_templates_sysadmin_update_v03[\s\S]*?notice_templates_sysadmin_delete_v03/i.test(finalHardening) ? pass("Notice-template write RLS is operation-specific and binds the Sysadmin actor on insert") : fail("Notice-template write RLS is overly broad or does not bind the creator");

/create policy "admin_notes_admin_insert"[\s\S]*?created_by=auth\.uid\(\)[\s\S]*?is_admin_mfa[\s\S]*?is_sysadmin_mfa[\s\S]*?target\.role='user'/i.test(finalHardening) ? pass("Internal admin-note targeting respects the user/Admin/Sysadmin hierarchy at the RLS boundary") : fail("Normal Admin sessions can attach internal notes to staff accounts");
/Admins may add internal notes only to regular-user accounts/.test(adminRoleSource) ? pass("Admin-note UI action mirrors the database staff-target restriction") : fail("Admin-note action does not provide the staff-target restriction before insert");

/drop policy if exists "settings_sysadmin_write"[\s\S]*?revoke insert, update, delete on public\.site_settings from anon, authenticated/i.test(finalHardening) ? pass("Site settings are browser-read/RPC-write, preventing direct bypass of atomic validation") : fail("Sysadmin browser sessions can still mutate site_settings outside the validated batch RPC");
const systemActionSource = read("src/actions/system.ts");
/sysadmin_set_settings/.test(systemActionSource) && !/from\(["']site_settings["']\)\.(?:insert|update|delete)/.test(systemActionSource) ? pass("Application settings writes use only the atomic settings RPC") : fail("Application source directly mutates site_settings outside the atomic RPC");

/create or replace function public\.is_valid_infobox_schema[\s\S]*?jsonb_array_length\(schema_value\)<=40[\s\S]*?count\(distinct lower\(field->>'key'\)\)[\s\S]*?count\(distinct lower\(field->>'label'\)\)/i.test(finalHardening) && /article_types_infobox_schema_valid_v03[\s\S]*?is_valid_infobox_schema\(infobox_schema\)/i.test(finalHardening) ? pass("Article-Type infobox schema shape, bounds, and uniqueness are enforced by PostgreSQL") : fail("Malformed Article-Type infobox schemas can bypass the Sysadmin editor and enter the database");

/ZIONXYOS_RELEASE_MANIFEST_ALLOWED_HOSTS/.test(updateSource) && /Release manifest host is not in the server allowlist/.test(updateSource) && /NODE_ENV==="production"/.test(updateSource) ? pass("Production release-manifest fetches require an exact server-side hostname allowlist") : fail("Configurable release manifests are not constrained by a production hostname allowlist");
/ZIONXYOS_RELEASE_MANIFEST_ALLOWED_HOSTS/.test(read(".env.example")) && /ZIONXYOS_RELEASE_MANIFEST_ALLOWED_HOSTS/.test(read("VERCEL_DEPLOY.md")) ? pass("Release-manifest hostname allowlist is documented in environment/deployment guidance") : fail("Release-manifest allowlist configuration is undocumented");

const markdownViewSource = read("src/components/MarkdownView.tsx");
/safeRenderedHref/.test(markdownViewSource) && /safeRenderedImageSrc/.test(markdownViewSource) && /url\.username \|\| url\.password/.test(markdownViewSource) && /url\.protocol !== "https:"/.test(markdownViewSource) && /\[blocked image\]/.test(markdownViewSource) ? pass("Markdown rendering explicitly rejects unsafe link/image protocols and credential-bearing URLs") : fail("Markdown URL safety relies only on dependency defaults");

/revision_categories_insert_v03[\s\S]*?categories c where c\.id=category_id and c\.active[\s\S]*?revision_categories_delete_v03/i.test(migration) && /revision_tags_insert_v03[\s\S]*?controlled_tags t where t\.id=tag_id and t\.active[\s\S]*?revision_tags_delete_v03/i.test(migration) && /revoke update on public\.revision_categories, public\.revision_tags from anon, authenticated/i.test(migration) ? pass("Revision taxonomy INSERT/DELETE RLS enforces active controlled taxonomy and removes unnecessary UPDATE") : fail("Revision taxonomy relations remain over-permissive or accept inactive controlled taxonomy");
const systemActionsCurrent = read("src/actions/system.ts");
/sysadmin_record_update_history/.test(systemActionsCurrent) && !/from\(["']system_update_history["']\)\.insert/.test(systemActionsCurrent) ? pass("System updater records history only through the protected RPC") : fail("System updater still writes audit history directly");
/sysadmin_record_update_history[\s\S]*?is_sysadmin_mfa\(auth\.uid\(\)\)[\s\S]*?Invalid update-history action[\s\S]*?details are too large/i.test(migration) && /revoke insert, update, delete on public\.system_update_history from anon, authenticated/i.test(migration) ? pass("System update history binds the Sysadmin actor and is browser-read/RPC-write") : fail("System update history can be forged or mutated directly by browser sessions");
/parsed\.username\|\|parsed\.password/.test(systemActionsCurrent) && /parsed\.port&&parsed\.port!==["']443["']/.test(systemActionsCurrent) ? pass("Deploy Hook guard rejects credentials and nonstandard ports") : fail("Deploy Hook URL guard accepts embedded credentials or nonstandard HTTPS ports");
/historyError/.test(systemActionsCurrent) && /audit record could not be saved/.test(systemActionsCurrent) && /Update-history recording also failed/.test(systemActionsCurrent) ? pass("Updater surfaces audit-history recording failures instead of silently losing them") : fail("Updater can silently lose update/deploy audit history");
/revoke insert, update, delete on public\.moderation_actions from anon, authenticated/i.test(migration) ? pass("Moderation writes are RPC-only at both RLS and table-privilege layers") : fail("Browser roles retain direct moderation_actions mutation privileges");
/revoke update, delete on public\.admin_user_notes from anon, authenticated/i.test(migration) ? pass("Internal admin notes are append-only to browser sessions") : fail("Browser sessions can rewrite or delete internal admin notes");
/drop policy if exists "announcements_sysadmin_update_v03"[\s\S]*?revoke update on public\.site_announcements from anon, authenticated/i.test(migration) ? pass("Published announcements are immutable; UI-supported mutation is create/delete only") : fail("Browser sessions retain an unused direct announcement UPDATE path");
/rpc\(["']is_active_user["']/.test(proxySource) && /active===true/.test(proxySource) && /role,suspended/.test(proxySource) ? pass("Blocked staff cannot bypass maintenance mode merely because their profile still has a staff role") : fail("Maintenance bypass trusts staff role without active-account moderation state");
/drop policy if exists "revisions_draft_author_admin_delete"[\s\S]*?revoke delete on public\.article_revisions from anon, authenticated/i.test(migration) ? pass("Individual revision hard-delete is unavailable to browser sessions, preserving editorial history") : fail("Browser sessions can still selectively hard-delete revision history");
const directRevisionDeletes = sourceFiles.flatMap((file) => { const source = fs.readFileSync(file, "utf8"); return /\.from\(["']article_revisions["']\)[\s\S]{0,160}?\.delete\(/.test(source) ? [path.relative(root,file)] : []; });
directRevisionDeletes.length ? fail(`Application source attempts direct revision DELETE: ${directRevisionDeletes.join(", ")}`) : pass("Application source does not depend on direct revision deletion");
const latestRevisionGuardStart = migration.lastIndexOf("create or replace function public.enforce_revision_permissions()");
const latestRevisionGuard = latestRevisionGuardStart >= 0 ? migration.slice(latestRevisionGuardStart, migration.indexOf("\n$$;", latestRevisionGuardStart) + 4) : "";
!/if public\.is_sysadmin_mfa\(auth\.uid\(\)\) then return new/i.test(latestRevisionGuard) && /old\.status='pending_review'/.test(latestRevisionGuard) && /This revision is no longer editable/.test(latestRevisionGuard) ? pass("Approved/rejected revision rows are immutable even to direct Sysadmin browser updates") : fail("Latest revision guard still permits privileged direct mutation of immutable history");
/revisions_author_admin_update[\s\S]*?is_admin_mfa\(auth\.uid\(\)\) and status='pending_review'/i.test(migration.slice(migration.lastIndexOf("-- Approved revision immutability."))) ? pass("Staff direct revision UPDATE RLS is limited to pending review rows") : fail("Staff direct revision UPDATE RLS can target immutable historical states");
/revision_categories_insert_v03[\s\S]*?r\.status='pending_review'[\s\S]*?revision_tags_insert_v03[\s\S]*?r\.status='pending_review'/i.test(migration.slice(migration.lastIndexOf("-- Approved revision immutability."))) ? pass("Approved revision category/tag relations are immutable to direct staff writes") : fail("Staff can mutate normalized taxonomy attached to approved revision history");
const latestArticleGuardStart = migration.lastIndexOf("create or replace function public.enforce_article_permissions()");
const latestArticleGuard = latestArticleGuardStart >= 0 ? migration.slice(latestArticleGuardStart, migration.indexOf("\n$$;", latestArticleGuardStart) + 4) : "";
!/if public\.is_sysadmin_mfa\(auth\.uid\(\)\) then return new/i.test(latestArticleGuard) && /Staff may only change page protection and featured status outside protected workflows/.test(latestArticleGuard) ? pass("Direct Sysadmin article UPDATE cannot rewrite canonical content outside protected workflows") : fail("Sysadmin direct article UPDATE still bypasses canonical-content workflow integrity");
/article_retire/.test(latestArticleGuard) && /Article retirement may only change retirement metadata/.test(latestArticleGuard) && /set_config\('zionxyos\.article_retire','1',true\)/.test(migration.slice(migration.lastIndexOf("create or replace function public.sysadmin_set_article_retired"))) ? pass("Article retirement uses a scoped RPC flag and can mutate retirement metadata only") : fail("Article retirement requires an overly broad Sysadmin article-update bypass");
/protection_changed/.test(latestArticleGuard) ? pass("Expired page-protection timestamps do not block unrelated staff metadata updates") : fail("Article trigger revalidates stale protection expiry on unrelated updates");
/create or replace function public\.enforce_media_asset_update[\s\S]*?Media object identity and metadata are immutable after upload[\s\S]*?Referenced media cannot be retired[\s\S]*?media\.retired[\s\S]*?media\.restored/i.test(migration) ? pass("Media metadata is immutable after upload and retirement/restore is audited") : fail("Sysadmin can retarget media metadata or retire referenced assets through direct UPDATE");
/media_assets_update_guard before update on public\.media_assets/i.test(migration) && /revoke all on function public\.enforce_media_asset_update\(\) from public, anon, authenticated/i.test(migration) ? pass("Media update integrity is enforced by a sealed database trigger") : fail("Media metadata guard trigger is missing or browser-callable");
(/enforce_taxonomy_creator_integrity/i.test(finalHardening) && /new\.created_by := auth\.uid\(\)/i.test(finalHardening) && /Taxonomy creator metadata is immutable/i.test(finalHardening)) ? pass("Taxonomy creator/creation metadata is database-bound and immutable") : fail("Taxonomy creator metadata can be forged through privileged direct writes");
/audit_taxonomy_change[\s\S]*?article_types_audit_v03[\s\S]*?categories_audit_v03[\s\S]*?controlled_tags_audit_v03/i.test(finalHardening) ? pass("Article Type, category, and controlled-tag CRUD are recorded in the audit trail") : fail("Basic taxonomy CRUD is not fully audit logged");
/article_types_sysadmin_insert_v03[\s\S]*?created_by=auth\.uid\(\)[\s\S]*?categories_sysadmin_insert_v03[\s\S]*?created_by=auth\.uid\(\)[\s\S]*?controlled_tags_sysadmin_insert_v03[\s\S]*?created_by=auth\.uid\(\)/i.test(finalHardening) ? pass("Taxonomy write RLS is operation-specific and binds Sysadmin authorship on insert") : fail("Taxonomy write RLS retains a broad policy or fails to bind insertion authorship");

/prevent_used_article_type_delete[\s\S]*?public\.articles[\s\S]*?public\.article_revisions[\s\S]*?deactivate it instead[\s\S]*?article_types_prevent_used_delete_v03/i.test(finalHardening) ? pass("In-use Article Types cannot be deleted through direct Sysadmin/PostgREST writes") : fail("Article Type deletion can null out live/historical article_type_id references despite the UI safeguard");

/create table if not exists public\.article_internal_links/i.test(migration) && /articles_sync_internal_links_v03/i.test(migration) && /limit 200/i.test(migration) && /grant select on public\.article_internal_links to anon, authenticated/i.test(migration) ? pass("Published internal links are normalized into a bounded read-only derived index") : fail("Internal-link utility pages lack a bounded normalized link index");
const latestBacklinks = migration.slice(migration.lastIndexOf("create or replace function public.wiki_backlinks"));
const latestBroken = migration.slice(migration.lastIndexOf("create or replace function public.wiki_broken_links"));
const latestOrphans = migration.slice(migration.lastIndexOf("create or replace function public.wiki_orphaned_pages"));
[latestBacklinks,latestBroken,latestOrphans].every((block) => /article_internal_links/.test(block.slice(0,2200))) && ![latestBacklinks,latestBroken,latestOrphans].some((block) => /regexp_matches/.test(block.slice(0,2200))) ? pass("Backlink/broken-link/orphan RPCs query the normalized link index instead of rescanning article content") : fail("A public link-analysis RPC still regex-scans canonical article content per request");
const backlinkPageSource = read("src/app/article/[slug]/backlinks/page.tsx");
const brokenLinksPageSource = read("src/app/special/broken-links/page.tsx");
const orphansPageSource = read("src/app/special/orphans/page.tsx");
/wiki_backlinks/.test(backlinkPageSource) && /wiki_broken_links/.test(brokenLinksPageSource) && /wiki_orphaned_pages/.test(orphansPageSource) && !/\.from\(["']articles["']\)\.select\(["'][^"']*content/.test(backlinkPageSource+brokenLinksPageSource+orphansPageSource) ? pass("Link-analysis pages no longer download all published article content into the application process") : fail("A public link-analysis page still scans article bodies in Next.js");

const recoverySource = read("src/lib/password-recovery.ts");
const updatePasswordPageSource = read("src/app/update-password/page.tsx");
const authCallbackRecoverySource = read("src/app/auth/callback/route.ts");
/AUTH_RECOVERY_STATE_SECRET must be a non-placeholder secret of at least 32 characters in production/.test(recoverySource) && /createHmac\("sha256"/.test(recoverySource) && /timingSafeEqual/.test(recoverySource) && /password_recovery_state/.test(recoverySource) && /password_recovery_grant/.test(recoverySource) ? pass("Password recovery state/grants are HMAC-signed, expiring, and fail closed on a weak production secret") : fail("Password recovery authorization lacks signed/expiring server state or a production secret gate");
/createPasswordRecoveryState\(email\)/.test(registrationActions) && /recovery_state=\$\{encodeURIComponent\(state\)\}/.test(registrationActions) && /isPasswordRecoveryStateValid\(recoveryState\)/.test(authCallbackRecoverySource) && /verifyPasswordRecoveryState\(recoveryState, user\.email\)/.test(authCallbackRecoverySource) ? pass("Password-reset PKCE callback requires a valid email-bound recovery state before granting reset access") : fail("Password reset callback can grant update-password access without an email-bound recovery state");
/httpOnly:\s*true/.test(recoverySource) && /sameSite:\s*"lax"/.test(recoverySource) && /path:\s*"\/update-password"/.test(recoverySource) && /maxAge:\s*GRANT_TTL_SECONDS/.test(recoverySource) && /PASSWORD_RECOVERY_GRANT_COOKIE/.test(authCallbackRecoverySource) ? pass("Password-reset grant is short-lived, HttpOnly, SameSite, and path-scoped") : fail("Password-reset grant cookie lacks short-lived HttpOnly/SameSite/path scoping");
/verifyPasswordRecoveryGrant\(grant,userData\.user\.id\)/.test(registrationActions) && /verifyPasswordRecoveryGrant\(grant,userData\.user\.id\)/.test(updatePasswordPageSource) && /maxAge:0/.test(registrationActions) && /signOut\(\{scope:"others"\}\)/.test(registrationActions) ? pass("Password reset requires the signed grant in both page/action, consumes it, and signs out other refresh-token sessions") : fail("A normal authenticated session can reach password reset or the recovery grant is reusable");
/AUTH_RECOVERY_STATE_SECRET/.test(read(".env.example")) && /AUTH_RECOVERY_STATE_SECRET/.test(read("VERCEL_DEPLOY.md")) && /AUTH_RECOVERY_STATE_SECRET/.test(read("RELEASE_CHECKLIST.md")) ? pass("Password-recovery signing-secret deployment requirements are documented") : fail("Password-recovery signing secret is missing from deployment guidance");

const publicHistorySource = read("src/app/article/[slug]/history/page.tsx");
const publicDiscussionSource = read("src/app/article/[slug]/discussion/page.tsx");
const categoryPageSource = read("src/app/categories/[name]/page.tsx");
const allPagesSource = read("src/app/special/all-pages/page.tsx");
const publicUsersSource = read("src/app/special/users/page.tsx");
const uncategorizedSource = read("src/app/special/uncategorized/page.tsx");
const pagerSource = read("src/components/Pager.tsx");
/\.range\(offset,offset\+PAGE_SIZE\)/.test(publicHistorySource) && /windowRows\.slice\(0,PAGE_SIZE\)/.test(publicHistorySource) && /Pager/.test(publicHistorySource) ? pass("Public revision history is paginated with a one-row lookahead for cross-boundary diffs") : fail("Public revision history can grow into an unbounded response or loses boundary diff navigation");
/\.range\(offset,offset\+PAGE_SIZE\)/.test(publicDiscussionSource) && /windowPosts\.slice\(0,PAGE_SIZE\)/.test(publicDiscussionSource) && /Pager/.test(publicDiscussionSource) ? pass("Public article discussions are paginated instead of loading every post") : fail("Public article discussions can load unbounded post history");
/wiki_category_context/.test(categoryPageSource) && /wiki_category_articles/.test(categoryPageSource) && /page_limit:PAGE_SIZE\+1/.test(categoryPageSource) && /create or replace function public\.wiki_category_context[\s\S]*?a\.depth<32[\s\S]*?limit 1000/i.test(migration) && /create or replace function public\.wiki_category_articles[\s\S]*?page_limit[\s\S]*?limit greatest/i.test(migration) ? pass("Category pages fetch only bounded hierarchy context plus paginated article results") : fail("Category pages retain an unbounded hierarchy/article relation fan-out");
/wiki_uncategorized_pages/.test(uncategorizedSource) && /create or replace function public\.wiki_uncategorized_pages[\s\S]*?not exists[\s\S]*?page_limit/i.test(migration) ? pass("Uncategorized-page discovery is bounded and database-side") : fail("Uncategorized pages require loading the full article/category relation set");
/\.range\(offset,offset\+PAGE_SIZE\)/.test(allPagesSource) && /\.range\(offset,offset\+PAGE_SIZE\)/.test(publicUsersSource) && /wiki-pager/.test(read("src/app/globals.css")) && /Page \{page\}/.test(pagerSource) ? pass("Large public page/user directories use reusable bounded pagination") : fail("A large public directory is still rendered as one oversized response");
const articleDetailSource = read("src/app/article/[slug]/page.tsx");
/wiki_related_articles/.test(articleDetailSource) && !/relatedLinksResult/.test(articleDetailSource) && /create or replace function public\.wiki_related_articles[\s\S]*?limit greatest/i.test(migration) ? pass("Related-article suggestions use a bounded database join instead of relation fan-out") : fail("Related articles still download broad category-relation fan-out into Next.js");
const latestRelatedArticles = migration.slice(migration.lastIndexOf("create or replace function public.wiki_related_articles"));
/select a\.id from public\.articles a where a\.id=article_uuid and a\.status='published' and a\.deleted_at is null/i.test(latestRelatedArticles.slice(0,1800)) ? pass("Related-article RPC qualifies article id references that overlap RETURNS TABLE output names") : fail("Related-article RPC leaves an ambiguous unqualified id reference inside a RETURNS TABLE function");
!/\b(?:a|r)\.(?:cover_media_id|video_media_id|article_type_id)\s*=\s*id\b/i.test(migration) && /a\.cover_media_id=media_assets\.id/i.test(migration) && /r\.cover_media_id=media_assets\.id/i.test(migration) && /a\.article_type_id=article_types\.id/i.test(migration) && /r\.article_type_id=article_types\.id/i.test(migration) ? pass("Nested RLS subqueries qualify outer id references instead of shadowing or ambiguously binding them") : fail("An RLS subquery leaves an outer id reference unqualified and vulnerable to shadowing/ambiguity");
const latestCategoryCounts = migration.slice(migration.lastIndexOf("create or replace function public.wiki_category_counts"));
/limit 5000/.test(latestCategoryCounts.slice(0,1800)) ? pass("Public category-count tree has an explicit result ceiling") : fail("Public category-count tree can return an unbounded taxonomy response");

const communityActionSource = read("src/actions/community.ts");
/returnMessage\(path:string/.test(communityActionSource) && /path\.includes\("\?"\)\?"&":"\?"/.test(communityActionSource) && /lastPage=Math\.max\(1,Math\.ceil/.test(communityActionSource) ? pass("Discussion/report action redirects preserve pagination queries and new posts return to their last page") : fail("Paginated discussion/report actions can build malformed return URLs or lose the posted message page");
/return_to/.test(publicDiscussionSource) && /safeReturnPath\(formData\.get\("return_to"\)/.test(adminRoleSource) && /withMessage\("success","Post removed by the administration\."\)/.test(adminRoleSource) ? pass("Discussion moderation preserves the current paginated return path safely") : fail("Removing a discussion post drops staff back onto the wrong page or trusts an unsafe return path");
/enforce_article_notice_limit[\s\S]*?pg_advisory_xact_lock[\s\S]*?notice_count>=20/i.test(migration) && /article_notices_limit_v03/.test(migration) ? pass("Editorial notices per article are concurrency-capped at the database boundary") : fail("An article can accumulate an unbounded number of editorial notice banners");

/rpc\("is_valid_report_target",\s*\{ target_kind: type, target_uuid: id \}\)/.test(communityActionSource) && !/let targetExists = false/.test(communityActionSource) ? pass("Report Server Action reuses the same authoritative target-validity RPC as report RLS") : fail("Report target validity is duplicated in application code and can drift from database policy");

const latestCategoryCycle = migration.slice(migration.lastIndexOf("create or replace function public.prevent_category_cycle"));
/depth_count>32/.test(latestCategoryCycle.slice(0,1800)) && /Category hierarchy cannot exceed 32 ancestor levels/.test(latestCategoryCycle.slice(0,1800)) ? pass("Category hierarchy depth is capped at the database boundary") : fail("A Sysadmin can create a pathological category chain deep enough to break recursive rendering");

const articlePageSource = read("src/app/article/[slug]/page.tsx");
/type RelatedArticle =/.test(articlePageSource) && /const related = \(relatedResult\.data \|\| \[\]\) as RelatedArticle\[\]/.test(articlePageSource) ? pass("Related-article RPC results have an explicit TypeScript shape") : fail("Related-article RPC results can fall back to implicit any under real Supabase typings");

/articles_protection_reason_length_v03[\s\S]*?char_length\(protection_reason\) <= 2000/i.test(finalHardening) ? pass("Page-protection reasons are bounded at the database boundary") : fail("Page-protection reason length depends only on the browser UI");
/audit_logs_metadata_size_v03[\s\S]*?pg_column_size\(metadata\) <= 65536/i.test(finalHardening) ? pass("Administrative audit metadata has a database-enforced size ceiling") : fail("Audit log metadata can grow without a database size ceiling");
/Retirement\/restore reason is too long/.test(finalHardening) && /char_length\(trim\(reason\)\) > 2000/.test(finalHardening) ? pass("Article retirement/restoration reason is bounded inside the privileged RPC") : fail("Retirement/restoration reason is bounded only by the UI");

/create policy "zionxyos_media_insert"[\s\S]*?consume_rate_limit\('media_upload',auth\.uid\(\)::text,30,3600\)[\s\S]*?consume_rate_limit\('media_upload',auth\.uid\(\)::text,10,3600\)/i.test(finalHardening) ? pass("Direct Storage uploads consume image/video rate limits inside Storage RLS") : fail("Direct Storage API callers can bypass media upload throttling");
/enforce_media_asset_object_match[\s\S]*?from storage\.objects[\s\S]*?MIME type does not match[\s\S]*?size does not match/i.test(finalHardening) && /media_assets_object_match_v03/.test(finalHardening) ? pass("Media metadata inserts must match an existing owned Storage object MIME/size") : fail("media_assets metadata can be fabricated without a matching Storage object");
const directUploadSource = read("src/components/DirectMediaUpload.tsx");
!/consume_rate_limit/.test(directUploadSource) && /storage\.from\(["']zionxyos-media["']\)\.upload/.test(directUploadSource) ? pass("Browser uploader relies on authoritative Storage-RLS throttling instead of double-consuming quota") : fail("Browser uploader duplicates or bypasses the authoritative Storage upload throttle");

/rate_limit_events_created_idx[\s\S]*?rate_limit_events\(created_at\)/i.test(finalHardening) ? pass("Rate-limit expiry cleanup has a dedicated created_at index") : fail("Rate-limit cleanup can degrade into a full-table expiry scan");

const docs = ["README.md", "UPGRADE_FROM_V0.1.md", "UPGRADE_FROM_V0.2.md", "VERCEL_DEPLOY.md", "RELEASE_CHECKLIST.md"];
const staleDocs = docs.filter((file) => /Zionxyos v0\.2\s+[—-](?!>\s*v0\.3)/i.test(read(file)) || /\b(?:Atualização|artigos|usuário|categoria|revisão|senha|página|administração)\b/i.test(read(file)));
staleDocs.length ? fail(`Release documentation is stale or not English-only: ${staleDocs.join(", ")}`) : pass("v0.3 release documentation is English-only and not branded as v0.2");
docs.every((file) => read(file).includes("v0.3") || read(file).includes("0.3.0")) ? pass("All release guides identify the v0.3 release") : fail("A release guide does not identify v0.3");
/No fictional sample content is seeded/.test(read("README.md")) && /does not seed fictional taxonomy/.test(read("UPGRADE_FROM_V0.2.md")) ? pass("Documentation preserves the no-sample-content requirement") : fail("No-sample-content requirement is missing from release documentation");
/npm run preflight/.test(read("VERCEL_DEPLOY.md")) && /npm run build/.test(read("RELEASE_CHECKLIST.md")) ? pass("Deployment docs require a real dependency-complete production build") : fail("Deployment docs do not require a real production build");
const releaseNotes = read("RELEASE_NOTES_0.3.0.md");
/0\.3\.0/.test(releaseNotes) && /npm run preflight/.test(releaseNotes) && /No fictional sample content|no fictional sample content/i.test(releaseNotes) ? pass("v0.3 release notes preserve the build gate and no-sample-content contract") : fail("v0.3 release notes are missing the build gate or no-sample-content contract");


async function loadTypeScript() {
  try { return await import("typescript"); } catch {}
  try {
    const globalRoot = execSync("npm root -g", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    return await import(pathToFileURL(path.join(globalRoot, "typescript/lib/typescript.js")).href);
  } catch { return null; }
}

try {
  const ts = await loadTypeScript();
  if (!ts) throw new Error("TypeScript package is unavailable");
  const syntaxErrors = [];
  for (const file of sourceFiles) {
    const source = fs.readFileSync(file, "utf8");
    const result = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext, jsx: ts.JsxEmit.ReactJSX }, fileName: file, reportDiagnostics: true });
    for (const diagnostic of result.diagnostics || []) if (diagnostic.category === ts.DiagnosticCategory.Error) syntaxErrors.push(`${path.relative(root, file)}: ${ts.flattenDiagnosticMessageText(diagnostic.messageText, " ")}`);
  }
  syntaxErrors.length ? fail(`TypeScript syntax/transpile errors: ${syntaxErrors.slice(0, 20).join(" | ")}`) : pass(`TypeScript parser accepted all ${sourceFiles.length} TS/TSX files`);
  const unusedImports = [];
  for (const file of sourceFiles) {
    const tree = ts.createSourceFile(file, fs.readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true, file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
    const names = [];
    for (const statement of tree.statements) {
      if (!ts.isImportDeclaration(statement) || !statement.importClause) continue;
      if (statement.importClause.name) names.push(statement.importClause.name.text);
      const bindings = statement.importClause.namedBindings;
      if (bindings && ts.isNamedImports(bindings)) for (const element of bindings.elements) names.push(element.name.text);
      if (bindings && ts.isNamespaceImport(bindings)) names.push(bindings.name.text);
    }
    const counts = new Map(names.map((name) => [name, 0]));
    const visit = (node) => {
      if (ts.isIdentifier(node) && counts.has(node.text)) {
        let cursor = node.parent; let inImport = false;
        while (cursor) { if (ts.isImportDeclaration(cursor)) { inImport = true; break; } if (ts.isSourceFile(cursor)) break; cursor = cursor.parent; }
        if (!inImport) counts.set(node.text, counts.get(node.text) + 1);
      }
      ts.forEachChild(node, visit);
    };
    visit(tree);
    for (const [name, count] of counts) if (count === 0) unusedImports.push(`${path.relative(root, file)}:${name}`);
  }
  unusedImports.length ? fail(`Unused TypeScript imports: ${unusedImports.slice(0, 20).join(", ")}`) : pass("TypeScript source has no unused imports");

  const sourceRoot = path.join(root, "src");
  const resolveLocal = (specifier, importer) => {
    let base = null;
    if (specifier.startsWith("@/")) base = path.join(sourceRoot, specifier.slice(2));
    else if (specifier.startsWith(".")) base = path.resolve(path.dirname(importer), specifier);
    if (!base) return null;
    const candidates = [base, `${base}.ts`, `${base}.tsx`, path.join(base, "index.ts"), path.join(base, "index.tsx")];
    return candidates.find((candidate) => fs.existsSync(candidate) && fs.statSync(candidate).isFile()) || null;
  };
  const exportCache = new Map();
  const localExports = (file) => {
    if (exportCache.has(file)) return exportCache.get(file);
    const result = { names: new Set(), hasDefault: false };
    exportCache.set(file, result);
    const tree = ts.createSourceFile(file, fs.readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true, file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
    for (const statement of tree.statements) {
      const modifiers = ts.canHaveModifiers(statement) ? ts.getModifiers(statement) : undefined;
      const exported = modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword);
      const defaulted = modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.DefaultKeyword);
      if (exported) {
        if (defaulted) result.hasDefault = true;
        if (statement.name && ts.isIdentifier(statement.name) && !defaulted) result.names.add(statement.name.text);
        if (ts.isVariableStatement(statement)) for (const declaration of statement.declarationList.declarations) if (ts.isIdentifier(declaration.name)) result.names.add(declaration.name.text);
      }
      if (ts.isExportAssignment(statement)) result.hasDefault = true;
      if (ts.isExportDeclaration(statement) && statement.exportClause && ts.isNamedExports(statement.exportClause)) for (const element of statement.exportClause.elements) result.names.add(element.name.text);
    }
    return result;
  };
  const importExportErrors = [];
  for (const file of sourceFiles) {
    const tree = ts.createSourceFile(file, fs.readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true, file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
    for (const statement of tree.statements) {
      if (!ts.isImportDeclaration(statement) || !statement.importClause || !ts.isStringLiteral(statement.moduleSpecifier)) continue;
      const target = resolveLocal(statement.moduleSpecifier.text, file);
      if (!target) continue;
      const exported = localExports(target);
      if (statement.importClause.name && !exported.hasDefault) importExportErrors.push(`${path.relative(root, file)} default <- ${statement.moduleSpecifier.text}`);
      const bindings = statement.importClause.namedBindings;
      if (bindings && ts.isNamedImports(bindings)) for (const element of bindings.elements) {
        const importedName = (element.propertyName || element.name).text;
        if (!exported.names.has(importedName)) importExportErrors.push(`${path.relative(root, file)} {${importedName}} <- ${statement.moduleSpecifier.text}`);
      }
    }
  }
  importExportErrors.length ? fail(`Local named/default import-export mismatches: ${importExportErrors.slice(0, 20).join(" | ")}`) : pass("Local named/default imports match their source exports");
} catch (error) { warn(`TypeScript parser check skipped: ${error instanceof Error ? error.message : String(error)}`); }

const report = ["# Zionxyos v0.3 Release Validation", "", `Generated: ${new Date().toISOString()}`, "", `- PASS: ${passed}`, `- WARN: ${warnings}`, `- FAIL: ${failed}`, "", "## Checks", "", ...details.map(([status, message]) => `- **${status}** — ${message}`), "", "## Build status", "", "This validator performs source, migration, policy-pattern, routing, import, CSS, and TypeScript syntax checks without requiring installed project dependencies. A real `npm install && npm run preflight` must still be executed in an environment with npm registry access before production deployment.", ""].join("\n");
fs.writeFileSync(path.join(root, "VALIDATION_REPORT.md"), report);
console.log(`\nRESULT  ${passed} PASS / ${warnings} WARN / ${failed} FAIL`);
process.exitCode = failed ? 1 : 0;
