import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getAuthContext } from "@/lib/auth";
import { getPublicSiteSettings } from "@/lib/settings";
import { formatDateShort } from "@/lib/utils";

export const dynamic="force-dynamic";
export const metadata={title:"Search",robots:{index:false,follow:true}};
type Result={id:string;title:string;slug:string;summary:string|null;article_type:string|null;categories:string[]|null;tags:string[]|null;updated_at:string;rank:number};

export default async function SearchPage({searchParams}:{searchParams:Promise<{q?:string;type?:string}>}){
  const{q="",type=""}=await searchParams;
  const query=q.trim().slice(0,200);
  const s=await createClient();
  const[context,settings,{data,error},{data:types}]=await Promise.all([
    getAuthContext(),
    getPublicSiteSettings(),
    query?s.rpc("wiki_search",{search_text:query,max_results:100}):Promise.resolve({data:[] as Result[],error:null}),
    s.from("article_types").select("id,name,slug").eq("active",true).order("sort_order").order("name"),
  ]);
  const all=(data||[])as Result[];
  const results=type?all.filter(x=>x.article_type===type):all;
  const canCreate=Boolean(context?.canContribute&&settings.articleCreationEnabled);
  return <div className="site-width content-page"><header className="classic-page-heading"><h1>Search</h1><p>Search published titles, summaries, article text, categories, tags, and contributors.</p></header><form className="search-page-form search-page-form-advanced" action="/search"><input name="q" defaultValue={query} autoFocus placeholder={`Search ${settings.siteName}`}/><select name="type" defaultValue={type}><option value="">All article types</option>{(types||[]).map(x=><option value={x.slug} key={x.id}>{x.name}</option>)}</select><button type="submit">Search</button></form>{error&&<div className="flash error">Search is temporarily unavailable.</div>}{query&&<p className="search-summary">Results for <strong>{query}</strong>{type?` in ${types?.find(x=>x.slug===type)?.name||type}`:""}: {results.length}</p>}<div className="search-results">{results.map(x=><article className="search-result" key={x.id}><h2><Link href={`/article/${x.slug}`}>{x.title}</Link></h2><div className="search-result-meta">{types?.find(t=>t.slug===x.article_type)?.name||x.article_type||"Article"} · updated {formatDateShort(x.updated_at)}</div>{x.summary&&<p>{x.summary}</p>}{!!x.categories?.length&&<div className="tiny-text">Categories: {x.categories.join(", ")}</div>}{!!x.tags?.length&&<div className="tiny-text">Tags: {x.tags.join(", ")}</div>}</article>)}{query&&!results.length&&<div className="wiki-message">No published page matches this search.{canCreate?<> You may <Link href="/dashboard/articles/new">create a new page</Link>.</>:!context&&settings.registrationEnabled?<> <Link href="/register">Create an account</Link> to contribute.</>:null}</div>}</div></div>;
}
