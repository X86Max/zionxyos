import { requireSysadmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { getAllSiteSettings } from "@/lib/settings";
import { APP_VERSION, REQUIRED_MIGRATION } from "@/lib/version";
import { formatBytes } from "@/lib/utils";

export const metadata = { title: "Production health · Administration" };
export const dynamic = "force-dynamic";

type Check = { label: string; status: "OK" | "WARN" | "FAIL"; detail: string };

export default async function AdminHealthPage() {
  await requireSysadmin();
  const supabase = await createClient();
  const settings = await getAllSiteSettings();
  const [migration, sysadminCount, typeCount, categoryCount, mediaCount] = await Promise.all([
    supabase.from("system_migrations").select("migration_id,status,version").eq("migration_id", REQUIRED_MIGRATION).maybeSingle(),
    supabase.from("profiles").select("id", { count: "exact", head: true }).eq("role", "sysadmin"),
    supabase.from("article_types").select("id", { count: "exact", head: true }).eq("active", true),
    supabase.from("categories").select("id", { count: "exact", head: true }).eq("active", true),
    supabase.from("media_assets").select("id", { count: "exact", head: true }).is("deleted_at", null),
  ]);

  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL || "";
  const prodUrlOk = /^https:\/\//i.test(siteUrl) && !/localhost|127\.0\.0\.1/i.test(siteUrl);
  const rateSalt = process.env.RATE_LIMIT_SALT || "";
  const rateSaltOk = rateSalt.length >= 24 && !/replace|development-only/i.test(rateSalt);
  const checks: Check[] = [
    { label: "Application version", status: "OK", detail: APP_VERSION },
    { label: "Production migration", status: migration.data?.status === "applied" ? "OK" : "FAIL", detail: migration.data ? `${migration.data.migration_id} · ${migration.data.status}` : "003 is not recorded as applied." },
    { label: "Protected sysadmin", status: sysadminCount.count === 1 ? "OK" : "FAIL", detail: `Expected exactly 1; database reports ${sysadminCount.count ?? 0}.` },
    { label: "Canonical site URL", status: process.env.NODE_ENV !== "production" || prodUrlOk ? "OK" : "FAIL", detail: siteUrl || "NEXT_PUBLIC_SITE_URL is missing." },
    { label: "Rate-limit salt", status: process.env.NODE_ENV !== "production" || rateSaltOk ? "OK" : "FAIL", detail: rateSaltOk ? "A non-placeholder server secret is configured." : "Use a long random RATE_LIMIT_SALT before production." },
    { label: "Legal contact", status: settings.legalContactEmail ? "OK" : "WARN", detail: settings.legalContactEmail || "Set a legal/privacy contact before public launch." },
    { label: "Article types", status: (typeCount.count || 0) > 0 ? "OK" : "WARN", detail: `${typeCount.count || 0} active. No default types are intentionally seeded.` },
    { label: "Categories", status: "OK", detail: `${categoryCount.count || 0} active. Taxonomy is intentionally sysadmin-created.` },
    { label: "Active media records", status: "OK", detail: `${mediaCount.count || 0} active assets. Image cap ${formatBytes(settings.maxImageBytes)}; video cap ${formatBytes(settings.maxVideoBytes)}.` },
    { label: "Vercel deploy hook", status: process.env.VERCEL_DEPLOY_HOOK_URL ? "OK" : "WARN", detail: process.env.VERCEL_DEPLOY_HOOK_URL ? "Configured server-side." : "Optional: configure it only when the in-app deploy trigger is wanted." },
  ];
  const failures = checks.filter((check) => check.status === "FAIL").length;
  const warnings = checks.filter((check) => check.status === "WARN").length;

  return <>
    <header className="classic-page-heading"><h1>Production health</h1><p>Read-only operational checks for the protected sysadmin. This page does not mutate the database or deployment.</p></header>
    <div className={`wiki-message ${failures ? "error" : warnings ? "warning" : "success"}`}><strong>{failures ? `${failures} blocking check${failures === 1 ? "" : "s"} failed.` : warnings ? `Core checks passed with ${warnings} warning${warnings === 1 ? "" : "s"}.` : "All displayed production checks passed."}</strong></div>
    <table className="management-table"><thead><tr><th>Check</th><th>Status</th><th>Details</th></tr></thead><tbody>{checks.map((check) => <tr key={check.label}><td>{check.label}</td><td><strong>{check.status}</strong></td><td>{check.detail}</td></tr>)}</tbody></table>
  </>;
}
