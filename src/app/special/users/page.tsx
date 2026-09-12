import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { formatDateShort } from "@/lib/utils";
import { Pager } from "@/components/Pager";
export const metadata={title:"Users"};
const PAGE_SIZE=200;
function pageNumber(raw?:string){const n=Number(raw);return Number.isInteger(n)&&n>0?Math.min(n,10000):1;}
export default async function UsersPage({searchParams}:{searchParams:Promise<{page?:string}>}){const q=await searchParams,page=pageNumber(q.page),offset=(page-1)*PAGE_SIZE;const s=await createClient();const{data,error}=await s.from("public_profiles").select("id,username,display_name,bio,created_at").order("username").order("id").range(offset,offset+PAGE_SIZE);if(error)throw new Error("Could not load the contributor directory.");const rows=data||[],hasNext=rows.length>PAGE_SIZE,items=rows.slice(0,PAGE_SIZE);return <div className="site-width content-page"><header className="classic-page-heading"><h1>Users</h1><p>Public contributor directory. Private account and moderation fields are not included.</p></header>{!items.length?<div className="wiki-message">No public profiles are available on this page.</div>:<table className="management-table"><thead><tr><th>User</th><th>Bio</th><th>Joined</th></tr></thead><tbody>{items.map(x=><tr key={x.id}><td><Link href={`/u/${x.username}`}>{x.display_name||`@${x.username}`}</Link><div className="tiny-text">@{x.username}</div></td><td>{x.bio||"—"}</td><td>{formatDateShort(x.created_at)}</td></tr>)}</tbody></table>}<Pager basePath="/special/users" page={page} hasNext={hasNext}/></div>}
