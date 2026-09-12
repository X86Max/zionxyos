import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Pager } from "@/components/Pager";

const PAGE_SIZE=100;
function pageNumber(raw?:string){const n=Number(raw);return Number.isInteger(n)&&n>0?Math.min(n,10000):1;}
type ContextRow={relation_kind:"current"|"ancestor"|"child";id:string;name:string;slug:string;description:string|null;parent_id:string|null;sort_order:number;depth:number};
type ArticleRow={id:string;title:string;slug:string;summary:string|null};

export async function generateMetadata({ params }: { params: Promise<{ name: string }> }): Promise<Metadata> {
  const { name } = await params;
  const supabase = await createClient();
  const { data: category, error } = await supabase.from("categories").select("name,slug,description").eq("slug", name).eq("active", true).maybeSingle();
  if (error) throw new Error("Could not load category metadata.");
  if (!category) return { title: "Category not found", robots: { index: false, follow: false } };
  const description = (category.description || `Published pages in the ${category.name} category on Zionxyos.`).slice(0, 300);
  return { title: `Category: ${category.name}`, description, alternates: { canonical: `/categories/${category.slug}` } };
}

export default async function CategoryPage({ params,searchParams }: { params: Promise<{ name: string }>;searchParams:Promise<{page?:string}> }) {
  const [{name},query]=await Promise.all([params,searchParams]);
  const page=pageNumber(query.page),offset=(page-1)*PAGE_SIZE;
  const supabase=await createClient();
  const{data:contextRows,error:contextError}=await supabase.rpc("wiki_category_context",{category_slug:name});
  if(contextError)throw new Error("Could not load the category hierarchy.");
  const rows=(contextRows||[])as ContextRow[];
  const category=rows.find(row=>row.relation_kind==="current");
  if(!category)notFound();
  const ancestors=rows.filter(row=>row.relation_kind==="ancestor").sort((a,b)=>b.depth-a.depth);
  const children=rows.filter(row=>row.relation_kind==="child").sort((a,b)=>a.sort_order-b.sort_order||a.name.localeCompare(b.name));
  const{data,error}=await supabase.rpc("wiki_category_articles",{category_uuid:category.id,page_offset:offset,page_limit:PAGE_SIZE+1});
  if(error)throw new Error("Could not load category articles.");
  const windowRows=(data||[])as ArticleRow[],hasNext=windowRows.length>PAGE_SIZE,articles=windowRows.slice(0,PAGE_SIZE);
  return <div className="site-width content-page"><nav className="category-breadcrumb" aria-label="Category hierarchy"><Link href="/categories">Categories</Link>{ancestors.map(item=><span key={item.id}> › <Link href={`/categories/${item.slug}`}>{item.name}</Link></span>)}<span> › {category.name}</span></nav><header className="classic-page-heading"><h1>Category: {category.name}</h1>{category.description&&<p>{category.description}</p>}</header>{children.length>0&&<section className="portal-box"><h2>Subcategories</h2><div className="category-cloud">{children.map(item=><Link href={`/categories/${item.slug}`} key={item.id}>{item.name}</Link>)}</div></section>}<section><h2>Pages in this category</h2>{!articles.length?<div className="wiki-message">No published pages are directly assigned to this category on this page.</div>:<ul className="category-article-list">{articles.map(article=><li key={article.id}><Link href={`/article/${article.slug}`}>{article.title}</Link>{article.summary&&<span> — {article.summary}</span>}</li>)}</ul>}<Pager basePath={`/categories/${category.slug}`} page={page} hasNext={hasNext}/></section></div>;
}
