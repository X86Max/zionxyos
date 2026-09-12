import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Pager } from "@/components/Pager";
export const metadata={title:"Uncategorized pages"};
const PAGE_SIZE=200;
function pageNumber(raw?:string){const n=Number(raw);return Number.isInteger(n)&&n>0?Math.min(n,10000):1;}
type Row={id:string;title:string;slug:string};
export default async function Uncategorized({searchParams}:{searchParams:Promise<{page?:string}>}){const q=await searchParams,page=pageNumber(q.page),offset=(page-1)*PAGE_SIZE;const s=await createClient();const{data,error}=await s.rpc("wiki_uncategorized_pages",{page_offset:offset,page_limit:PAGE_SIZE+1});if(error)throw new Error("Could not load uncategorized pages.");const rows=(data||[])as Row[],hasNext=rows.length>PAGE_SIZE,items=rows.slice(0,PAGE_SIZE);return <div className="site-width content-page"><header className="classic-page-heading"><h1>Uncategorized pages</h1><p>Published pages with no normalized category assignment.</p></header>{!items.length?<div className="wiki-message success">No uncategorized published pages appear on this page.</div>:<ul>{items.map(x=><li key={x.id}><Link href={`/article/${x.slug}`}>{x.title}</Link></li>)}</ul>}<Pager basePath="/special/uncategorized" page={page} hasNext={hasNext}/></div>}
