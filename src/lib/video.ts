import { safeMediaUrl } from "@/lib/media-url";

export type VideoInfo =
  | { kind: "youtube"; embedUrl: string }
  | { kind: "vimeo"; embedUrl: string }
  | { kind: "direct"; url: string }
  | { kind: "link"; url: string };

export function parseVideoUrl(raw: string | null | undefined): VideoInfo | null {
  if (!raw) return null;

  try {
    const safe = safeMediaUrl(raw);
    if (!safe) return null;
    const url = new URL(safe);

    const host = url.hostname.replace(/^www\./, "");

    if (host === "youtu.be") {
      const id = url.pathname.split("/").filter(Boolean)[0];
      if (id) return { kind: "youtube", embedUrl: `https://www.youtube-nocookie.com/embed/${encodeURIComponent(id)}` };
    }

    if (host === "youtube.com" || host === "m.youtube.com") {
      const id =
        url.searchParams.get("v") ||
        (url.pathname.startsWith("/shorts/") ? url.pathname.split("/")[2] : null) ||
        (url.pathname.startsWith("/embed/") ? url.pathname.split("/")[2] : null);
      if (id) return { kind: "youtube", embedUrl: `https://www.youtube-nocookie.com/embed/${encodeURIComponent(id)}` };
    }

    if (host === "vimeo.com" || host === "player.vimeo.com") {
      const id = url.pathname.split("/").filter(Boolean).find((part) => /^\d+$/.test(part));
      if (id) return { kind: "vimeo", embedUrl: `https://player.vimeo.com/video/${id}` };
    }

    if (/\.(mp4|webm|ogg)(\?.*)?$/i.test(url.toString())) {
      return { kind: "direct", url: url.toString() };
    }

    return { kind: "link", url: url.toString() };
  } catch {
    return null;
  }
}
