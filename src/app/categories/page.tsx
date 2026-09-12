import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

type Row = { category_id: string; category_name: string; category_slug: string; parent_id: string | null; article_count: number };

function CategoryNode({ row, childrenByParent }: { row: Row; childrenByParent: Map<string | null, Row[]> }) {
  const children = childrenByParent.get(row.category_id) || [];
  return <div className="public-category-node"><div><Link href={`/categories/${row.category_slug}`}>{row.category_name}</Link> <small>({row.article_count})</small></div>{children.length > 0 && <div className="public-category-children">{children.map((child) => <CategoryNode row={child} childrenByParent={childrenByParent} key={child.category_id} />)}</div>}</div>;
}

export default async function CategoriesPage() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("wiki_category_counts");
  const rows = (data || []) as Row[];
  const activeIds = new Set(rows.map((row) => row.category_id));
  const childrenByParent = new Map<string | null, Row[]>();
  for (const row of rows) {
    const parent = row.parent_id && activeIds.has(row.parent_id) ? row.parent_id : null;
    childrenByParent.set(parent, [...(childrenByParent.get(parent) || []), row]);
  }
  const roots = childrenByParent.get(null) || [];

  return <div className="site-width content-page"><header className="classic-page-heading"><h1>Categories</h1><p>Hierarchical classification maintained by the Zionxyos sysadmin.</p></header>{!rows.length ? <div className="wiki-message">There are no categories yet.</div> : <div className="category-tree-public">{roots.map((root) => <CategoryNode key={root.category_id} row={root} childrenByParent={childrenByParent} />)}</div>}</div>;
}
