import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Pager } from "@/components/Pager";
export const metadata={title:"All pages"};
const PAGE_SIZE=200;
function pageNumber(raw?:string){const n=Number(raw);return Number.isInteger(n)&&n>0?Math.min(n,10000):1;}
export default async function AllPages({searchParams}:{searchParams:Promise<{page?:string}>}){const q=await searchParams,page=pageNumber(q.page),offset=(page-1)*PAGE_SIZE;const s=await createClient();const{data,error}=await s.from("articles").select("id,title,slug,summary").eq("status","published").is("deleted_at",null).order("title").order("id").range(offset,offset+PAGE_SIZE);if(error)throw new Error("Could not load all pages.");const rows=data||[],hasNext=rows.length>PAGE_SIZE,items=rows.slice(0,PAGE_SIZE);return <div className="site-width content-page"><header className="classic-page-heading"><h1>All pages</h1><p>Alphabetical list of published Zionxyos articles.</p></header>{!items.length?<div className="wiki-message">There are no published pages on this page.</div>:<ul className="alphabetic-page-list">{items.map(x=><li key={x.id}><Link href={`/article/${x.slug}`}>{x.title}</Link>{x.summary&&<span> — {x.summary}</span>}</li>)}</ul>}<Pager basePath="/special/all-pages" page={page} hasNext={hasNext}/></div>}
