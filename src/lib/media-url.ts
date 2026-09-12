const LOCAL_MEDIA_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

function normalizedHostname(url: URL) { return url.hostname.replace(/^\[|\]$/g, ""); }

export function safeMediaUrl(raw: string | null | undefined) {
  const value = raw?.trim();
  if (!value) return null;
  try {
    const url = new URL(value);
    if (url.username || url.password) return null;
    const localHttp = process.env.NODE_ENV !== "production" && url.protocol === "http:" && LOCAL_MEDIA_HOSTS.has(normalizedHostname(url));
    if (url.protocol !== "https:" && !localHttp) return null;
    return url.toString();
  } catch {
    return null;
  }
}

export function requireMediaUrl(raw: FormDataEntryValue | null) {
  const value = String(raw || "").trim().slice(0, 2000);
  if (!value) return null;
  const safe = safeMediaUrl(value);
  if (!safe) throw new Error("Media URLs must use HTTPS and must not contain embedded credentials.");
  return safe;
}
