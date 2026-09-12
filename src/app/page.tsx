import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getAuthContext } from "@/lib/auth";
import { getPublicSiteSettings } from "@/lib/settings";
import { formatDateShort } from "@/lib/utils";

export const dynamic = "force-dynamic";
type CategoryCount={category_id:string;category_name:string;category_slug:string;parent_id:string|null;article_count:number};

export default async function HomePage({searchParams}:{searchParams:Promise<{q?:string}>}){
  const {q}=await searchParams;
  const s=await createClient();
  const [context,settings,{count:articleCount},{count:userCount},{data:featured},{data:latest},{data:categories},{data:revisions}]=await Promise.all([
    getAuthContext(),
    getPublicSiteSettings(),
    s.from("articles").select("id",{count:"exact",head:true}).eq("status","published").is("deleted_at",null),
    s.from("public_profiles").select("id",{count:"exact",head:true}),
    s.from("articles").select("id,title,slug,summary,updated_at").eq("status","published").is("deleted_at",null).eq("featured",true).order("updated_at",{ascending:false}).limit(1).maybeSingle(),
    s.from("articles").select("id,title,slug,summary,article_type,updated_at").eq("status","published").is("deleted_at",null).order("published_at",{ascending:false}).limit(8),
    s.rpc("wiki_category_counts"),
    s.from("article_revisions").select("id,article_id,author_id,title,edit_summary,reviewed_at,created_at").eq("status","approved").order("reviewed_at",{ascending:false}).limit(8),
  ]);
  const authorIds=[...new Set((revisions||[]).map(x=>x.author_id))];
  const articleIds=[...new Set((revisions||[]).map(x=>x.article_id))];
  const[{data:authors},{data:revisionArticles}]=await Promise.all([
    authorIds.length?s.from("public_profiles").select("id,username").in("id",authorIds):Promise.resolve({data:[]}),
    articleIds.length?s.from("articles").select("id,slug").in("id",articleIds).eq("status","published").is("deleted_at",null):Promise.resolve({data:[]}),
  ]);
  const authorMap=new Map((authors||[]).map(x=>[x.id,x.username]));
  const slugMap=new Map((revisionArticles||[]).map(x=>[x.id,x.slug]));
  const cats=(categories||[])as CategoryCount[];
  const canCreate=Boolean(context?.canContribute&&settings.articleCreationEnabled);
  return <div className="site-width wiki-home">
    <section className="welcome-box"><div><h1>Welcome to <strong>{settings.siteName}</strong></h1><p>{settings.tagline}</p></div><div className="wiki-stats"><strong>{articleCount||0}</strong> articles · <strong>{userCount||0}</strong> registered contributors</div></section>
    <form className="home-search" action="/search"><input name="q" defaultValue={q||""} placeholder="Search articles, content, categories, tags, and contributors"/><button type="submit">Search</button></form>
    <div className="home-columns"><section className="portal-box featured-box"><h2>Featured article</h2>{featured?<><h3><Link href={`/article/${featured.slug}`}>{featured.title}</Link></h3><p>{featured.summary||"This page has been selected as a featured article."}</p><div className="portal-footer"><Link href={`/article/${featured.slug}`}>Read the full article →</Link></div></>:<div className="empty-inline">No article has been featured yet.</div>}</section><section className="portal-box"><h2>Explore {settings.siteName}</h2><ul className="link-list two-column-list"><li><Link href="/categories">Browse categories</Link></li><li><Link href="/recent-changes">Recent changes</Link></li><li><Link href="/random">Random article</Link></li><li><Link href="/special">Special pages</Link></li>{canCreate?<li><Link href="/dashboard/articles/new">Create a page</Link></li>:!context&&settings.registrationEnabled?<li><Link href="/register">Create an account</Link></li>:null}<li><Link href="/about">About {settings.siteName}</Link></li></ul></section></div>
    <div className="home-columns"><section className="portal-box"><h2>Recent articles</h2>{!latest?.length?<div className="empty-inline">The encyclopedia does not have any published articles yet.</div>:<ul className="article-index-list">{latest.map(x=><li key={x.id}><Link href={`/article/${x.slug}`}>{x.title}</Link>{x.summary&&<span> — {x.summary}</span>}</li>)}</ul>}</section><section className="portal-box"><h2>Categories</h2>{!cats.length?<div className="empty-inline">No active category contains published pages yet.</div>:<div className="category-cloud">{cats.slice(0,16).map(x=><Link href={`/categories/${x.category_slug}`} key={x.category_id}>{x.category_name} <small>({x.article_count})</small></Link>)}</div>}<div className="portal-footer"><Link href="/categories">View all categories →</Link></div></section></div>
    <section className="portal-box recent-home"><h2>Recent changes</h2>{!revisions?.length?<div className="empty-inline">No published revisions have been recorded yet.</div>:<table className="compact-table"><tbody>{revisions.filter(x=>slugMap.has(x.article_id)).map(x=><tr key={x.id}><td className="nowrap">{formatDateShort(x.reviewed_at||x.created_at)}</td><td><Link href={`/article/${slugMap.get(x.article_id)}`}>{x.title}</Link></td><td>@{authorMap.get(x.author_id)||"unknown"}</td><td>{x.edit_summary||"no edit summary"}</td></tr>)}</tbody></table>}<div className="portal-footer"><Link href="/recent-changes">Full list →</Link></div></section>
  </div>;
}
