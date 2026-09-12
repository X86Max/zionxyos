import type { MetadataRoute } from "next";
import { getCanonicalSiteUrl } from "@/lib/site-url";

export default function robots(): MetadataRoute.Robots {
  const base = getCanonicalSiteUrl();
  return {
    rules: [
      { userAgent: "*", allow: "/", disallow: ["/admin/", "/dashboard/", "/auth/", "/mfa", "/update-password", "/legal/accept", "/search", "/random", "/recent-changes", "/special/"] },
    ],
    sitemap: `${base.replace(/\/$/, "")}/sitemap.xml`,
  };
}
