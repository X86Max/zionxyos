import { redirect } from "next/navigation";
import { getAuthContext } from "@/lib/auth";
import { formatDate } from "@/lib/utils";
export const metadata={title:"Account restricted"};
export default async function SuspendedPage(){const c=await getAuthContext();if(!c)redirect("/login");if(!c.blocked)redirect("/dashboard");const action=c.blockedAction;return <div className="site-width content-page narrow-page"><header className="classic-page-heading"><h1>Account access restricted</h1></header><div className="wiki-message error"><strong>Your account is currently suspended or banned.</strong>{action?.reason&&<p>Reason: {action.reason}</p>}{action?.expires_at&&<p>Restriction expires: {formatDate(action.expires_at)}</p>}<p>Published contributions remain part of the encyclopedia unless separately removed through the editorial process.</p></div></div>}
