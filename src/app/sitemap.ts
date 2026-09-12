import type { MetadataRoute } from "next";
import { createClient } from "@/lib/supabase/server";
import { getCanonicalSiteUrl } from "@/lib/site-url";

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const base = getCanonicalSiteUrl();
  const supabase = await createClient();
  const [{ data: articles }, { data: categories }, { data: profiles }] = await Promise.all([
    supabase.from("articles").select("slug,updated_at").eq("status", "published").is("deleted_at", null).order("updated_at", { ascending: false }).limit(5000),
    supabase.from("categories").select("slug,updated_at").eq("active", true).order("updated_at", { ascending: false }).limit(2000),
    supabase.from("public_profiles").select("username,updated_at").order("updated_at", { ascending: false }).limit(5000),
  ]);
  const fixed = ["", "/categories", "/about", "/legal/terms", "/legal/privacy", "/legal/guidelines"];
  return [
    ...fixed.map((path) => ({ url: `${base}${path}`, changeFrequency: path === "" ? "daily" as const : "weekly" as const })),
    ...(articles || []).map((article) => ({ url: `${base}/article/${article.slug}`, lastModified: article.updated_at, changeFrequency: "weekly" as const })),
    ...(categories || []).map((category) => ({ url: `${base}/categories/${category.slug}`, lastModified: category.updated_at, changeFrequency: "weekly" as const })),
    ...(profiles || []).map((profile) => ({ url: `${base}/u/${profile.username}`, lastModified: profile.updated_at, changeFrequency: "weekly" as const })),
  ];
}
