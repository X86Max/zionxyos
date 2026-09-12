import type { NextConfig } from "next";

function supabaseSources() {
  const raw = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!raw) return ["https://*.supabase.co", "wss://*.supabase.co"];
  try {
    const url = new URL(raw);
    return [url.origin, `${url.protocol === "https:" ? "wss:" : "ws:"}//${url.host}`];
  } catch {
    return ["https://*.supabase.co", "wss://*.supabase.co"];
  }
}

const nextConfig: NextConfig = {
  poweredByHeader: false,
  async headers() {
    const connect = ["'self'", ...supabaseSources()].join(" ");
    const csp = [
      "default-src 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      "frame-ancestors 'none'",
      "form-action 'self'",
      "script-src 'self' 'unsafe-inline'",
      "style-src 'self' 'unsafe-inline'",
      "font-src 'self' data:",
      "img-src 'self' data: blob: https:",
      "media-src 'self' blob: https:",
      "frame-src https://www.youtube-nocookie.com https://player.vimeo.com",
      `connect-src ${connect}`,
      "manifest-src 'self'",
    ].join("; ");
    return [{ source: "/:path*", headers: [
      { key: "X-Content-Type-Options", value: "nosniff" },
      { key: "X-Frame-Options", value: "DENY" },
      { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
      { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
      ...(process.env.NODE_ENV === "production" ? [
        { key: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains" },
        { key: "Content-Security-Policy", value: csp },
      ] : []),
    ] }];
  },
};
export default nextConfig;
