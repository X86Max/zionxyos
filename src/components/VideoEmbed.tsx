import { parseVideoUrl } from "@/lib/video";

export function VideoEmbed({ url }: { url?: string | null }) {
  const video = parseVideoUrl(url);
  if (!video) return null;

  if (video.kind === "youtube" || video.kind === "vimeo") {
    return (
      <div className="video-frame">
        <iframe
          src={video.embedUrl}
          title="Article video"
          loading="lazy"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
          allowFullScreen
          referrerPolicy="no-referrer"
        />
      </div>
    );
  }

  if (video.kind === "direct") {
    return (
      <video className="direct-video" controls preload="metadata">
        <source src={video.url} />
        Your browser does not support HTML5 video.
      </video>
    );
  }

  return (
    <p>
      <a href={video.url} target="_blank" rel="noreferrer noopener">
        Open video
      </a>
    </p>
  );
}
