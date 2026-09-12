/* eslint-disable @next/next/no-img-element -- Article Markdown may contain validated runtime image URLs from arbitrary HTTPS hosts. */
import Link from "next/link";
import type { ReactNode } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { headingIds, prepareWikiMarkdown, type WikiCitation } from "@/lib/wiki";

function safeRenderedHref(raw?: string) {
  if (!raw) return undefined;
  if (raw.startsWith("#")) return raw;
  if (raw.startsWith("/") && !raw.startsWith("//") && !raw.includes("\\")) return raw;
  try {
    const url = new URL(raw);
    if (url.username || url.password) return undefined;
    return url.protocol === "https:" || url.protocol === "http:" ? url.toString() : undefined;
  } catch { return undefined; }
}

function safeRenderedImageSrc(raw?: string) {
  if (!raw) return undefined;
  if (raw.startsWith("/") && !raw.startsWith("//") && !raw.includes("\\")) return raw;
  try {
    const url = new URL(raw);
    if (url.username || url.password || url.protocol !== "https:") return undefined;
    return url.toString();
  } catch { return undefined; }
}

function References({ citations }: { citations: WikiCitation[] }) {
  if (!citations.length) return null;

  return (
    <section className="references-section" aria-labelledby="references-heading">
      <h2 id="references-heading">References</h2>
      <ol className="references-list">
        {citations.map((citation) => (
          <li id={`cite-${citation.number}`} key={citation.number}>
            {citation.author && <>{citation.author}. </>}
            {citation.url ? (
              <a href={citation.url} target="_blank" rel="noreferrer noopener">
                {citation.title || citation.url}
              </a>
            ) : (
              <span>{citation.title || "Untitled reference"}</span>
            )}
            {citation.site && <>. <em>{citation.site}</em></>}
            {citation.date && <>. {citation.date}</>}
            {citation.accessed && <>. Accessed {citation.accessed}</>}
            {citation.markers.map((marker, index) => (
              <a className="reference-back" href={`#${marker}`} key={marker} aria-label="Back to citation">
                ↑{citation.markers.length > 1 ? index + 1 : ""}
              </a>
            ))}
          </li>
        ))}
      </ol>
    </section>
  );
}

export function MarkdownView({
  content,
  internalLinks = {},
}: {
  content: string;
  internalLinks?: Record<string, string>;
}) {
  if (!content.trim()) {
    return <p className="muted">This article does not have body content yet.</p>;
  }

  const prepared = prepareWikiMarkdown(content);
  const ids = headingIds(content);
  let headingIndex = 0;

  const heading = (Tag: "h2" | "h3" | "h4") => function WikiHeading({ children }: { children?: ReactNode }) {
    const id = ids[headingIndex++] || undefined;
    return (
      <Tag id={id}>
        {children}
        {id && <a href={`#${id}`} className="heading-anchor" aria-label="Link to this section">§</a>}
      </Tag>
    );
  };

  return (
    <div className="markdown wiki-markdown">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          h2: heading("h2"),
          h3: heading("h3"),
          h4: heading("h4"),
          img: ({ src, alt, title }) => { const safeSrc = typeof src === "string" ? safeRenderedImageSrc(src) : undefined; return safeSrc ? <img src={safeSrc} alt={alt || ""} title={title} loading="lazy" referrerPolicy="no-referrer" /> : <span className="muted">[blocked image]</span>; },
          a: ({ href, children, title }) => {
            if (href?.startsWith("/__wiki/")) {
              const target = decodeURIComponent(href.replace("/__wiki/", ""));
              const slug = internalLinks[target.toLocaleLowerCase("en-US")];
              if (slug) return <Link href={`/article/${slug}`}>{children}</Link>;
              return <Link className="new" href={`/search?q=${encodeURIComponent(target)}`} title={`The article “${target}” does not exist yet`}>{children}</Link>;
            }

            if (href?.startsWith("#cite-") && title?.startsWith("cite-marker-")) {
              return <sup id={title} className="reference-marker"><a href={href}>{children}</a></sup>;
            }

            const safeHref = safeRenderedHref(href);
            if (!safeHref) return <span>{children}</span>;
            const external = safeHref.startsWith("http://") || safeHref.startsWith("https://");
            return (
              <a href={safeHref} target={external ? "_blank" : undefined} rel={external ? "noreferrer noopener" : undefined}>
                {children}
              </a>
            );
          },
        }}
      >
        {prepared.markdown}
      </ReactMarkdown>
      <References citations={prepared.citations} />
    </div>
  );
}
