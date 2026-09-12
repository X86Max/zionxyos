function normalizedHostname(url: URL) {
  return url.hostname.replace(/^\[|\]$/g, "");
}

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

export function getSupabasePublicConfig() {
  const rawUrl = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim() || "";
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim() || "";
  if (!rawUrl) throw new Error("NEXT_PUBLIC_SUPABASE_URL is required.");
  if (!key || /replace[_-]?me|your[_-]?project|placeholder/i.test(key) || key.length < 20) {
    throw new Error("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY is missing or still uses a placeholder value.");
  }

  let url: URL;
  try { url = new URL(rawUrl); }
  catch { throw new Error("NEXT_PUBLIC_SUPABASE_URL must be an absolute URL."); }

  if (url.username || url.password) throw new Error("NEXT_PUBLIC_SUPABASE_URL must not contain credentials.");
  if (url.pathname !== "/" || url.search || url.hash) throw new Error("NEXT_PUBLIC_SUPABASE_URL must contain only the project origin.");
  const local = LOCAL_HOSTS.has(normalizedHostname(url));
  const production = process.env.NODE_ENV === "production";
  if (production && local) throw new Error("NEXT_PUBLIC_SUPABASE_URL cannot use localhost in production.");
  if (url.protocol !== "https:" && !(local && !production && url.protocol === "http:")) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL must use HTTPS outside local development.");
  }
  if (!local && url.port && url.port !== "443") throw new Error("NEXT_PUBLIC_SUPABASE_URL must use the standard HTTPS port.");

  return { url: url.origin, publishableKey: key };
}
