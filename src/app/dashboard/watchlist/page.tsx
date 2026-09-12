import Link from "next/link";
import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { formatDate } from "@/lib/utils";
import { toggleWatchAction } from "@/actions/community";

type WatchedArticle={id:string;title:string;slug:string;summary:string|null;updated_at:string};
export const metadata={title:"Watchlist"};

export default async function WatchlistPage(){
  const c=await requireUser();
  const s=await createClient();
  const{data:watch}=await s.from("watchlist").select("article_id,created_at").eq("user_id",c.user.id).order("created_at",{ascending:false});
  const ids=(watch||[]).map(x=>x.article_id);
  const{data:articles}=ids.length?await s.from("articles").select("id,title,slug,summary,updated_at").in("id",ids).eq("status","published").is("deleted_at",null):{data:[]};
  const map=new Map<string,WatchedArticle>(((articles||[]) as WatchedArticle[]).map(x=>[x.id,x]));
  return <>
    <header className="classic-page-heading"><h1>Watchlist</h1><p>Pages you marked with “Watch”. Retired pages can still be removed from this list.</p></header>
    {!watch?.length?<div className="wiki-message">Your watchlist is empty.</div>:<table className="management-table"><thead><tr><th>Page</th><th>Last updated</th><th>Added to watchlist</th><th></th></tr></thead><tbody>{watch.map(x=>{const a=map.get(x.article_id);return <tr key={x.article_id}><td>{a?<><Link href={`/article/${a.slug}`}>{a.title}</Link>{a.summary&&<div className="tiny-text">{a.summary}</div>}</>:<em>Unavailable or retired page</em>}</td><td>{a?formatDate(a.updated_at):"—"}</td><td>{formatDate(x.created_at)}</td><td><form action={toggleWatchAction}><input type="hidden" name="article_id" value={x.article_id}/><button className="button small" type="submit">Unwatch</button></form></td></tr>})}</tbody></table>}
  </>;
}
