import Link from "next/link";

export function Pager({ basePath, page, hasNext }: { basePath: string; page: number; hasNext: boolean }) {
  if (page <= 1 && !hasNext) return null;
  const href = (target: number) => `${basePath}${basePath.includes("?") ? "&" : "?"}page=${target}`;
  return <nav className="wiki-pager" aria-label="Pagination">
    {page > 1 ? <Link className="button secondary" href={href(page - 1)}>← Previous</Link> : <span />}
    <span>Page {page}</span>
    {hasNext ? <Link className="button secondary" href={href(page + 1)}>Next →</Link> : <span />}
  </nav>;
}
