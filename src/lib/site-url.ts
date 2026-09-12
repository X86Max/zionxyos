const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

function normalizedHostname(url: URL) { return url.hostname.replace(/^\[|\]$/g, ""); }

export function getCanonicalSiteUrl() {
  const raw = process.env.NEXT_PUBLIC_SITE_URL?.trim();
  if (!raw) {
    if (process.env.NODE_ENV === "production") {
      throw new Error("NEXT_PUBLIC_SITE_URL is required for a production Zionxyos build.");
    }
    return "http://localhost:3000";
  }

  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error("NEXT_PUBLIC_SITE_URL must be an absolute URL.");
  }

  const local = LOCAL_HOSTS.has(normalizedHostname(url));
  const production = process.env.NODE_ENV === "production" || process.env.VERCEL_ENV === "production";
  if (production && local) throw new Error("NEXT_PUBLIC_SITE_URL cannot use localhost in a production deployment.");
  const secure = url.protocol === "https:";
  const localHttp = !production && local && url.protocol === "http:";
  if (!secure && !localHttp) throw new Error("NEXT_PUBLIC_SITE_URL must use HTTPS outside localhost.");
  if (url.username || url.password) throw new Error("NEXT_PUBLIC_SITE_URL must not contain credentials.");
  if (!local && url.port && url.port !== "443") throw new Error("NEXT_PUBLIC_SITE_URL must use the standard HTTPS port.");
  if (url.pathname !== "/" || url.search || url.hash) throw new Error("NEXT_PUBLIC_SITE_URL must contain only the site origin, without a path, query, or fragment.");

  return url.origin;
}
