import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
export const metadata={title:"Orphaned pages"};
type Orphan={id:string;title:string;slug:string};
export default async function Orphans(){const s=await createClient();const{data,error}=await s.rpc("wiki_orphaned_pages",{max_results:1000});if(error)throw new Error("Could not calculate orphaned pages.");const items=(data||[])as Orphan[];return <div className="site-width content-page"><header className="classic-page-heading"><h1>Orphaned pages</h1><p>Published pages that receive no internal links from other published pages. Up to 1,000 results are shown.</p></header>{!items.length?<div className="wiki-message success">No orphaned pages were found.</div>:<ul>{items.map(x=><li key={x.id}><Link href={`/article/${x.slug}`}>{x.title}</Link></li>)}</ul>}</div>}
