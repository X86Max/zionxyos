import { extractToc } from "@/lib/wiki";

export function TableOfContents({ content }: { content: string }) {
  const entries = extractToc(content);
  if (entries.length < 2) return null;

  return (
    <nav className="toc" aria-label="Contents">
      <div className="toc-title">Contents</div>
      <ol>
        {entries.map((entry, index) => (
          <li className={`toc-level-${entry.level}`} key={`${entry.id}-${index}`}>
            <a href={`#${entry.id}`}>{entry.text}</a>
          </li>
        ))}
      </ol>
    </nav>
  );
}
