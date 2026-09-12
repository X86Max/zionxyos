import Link from "next/link";
import { requireUser } from "@/lib/auth";
import { exitUserViewAction } from "@/actions/admin";
import { getPublicSiteSettings } from "@/lib/settings";

export const metadata = { robots: { index: false, follow: false } };

export default async function DashboardLayout({children}:{children:React.ReactNode}){const[c,settings]=await Promise.all([requireUser(),getPublicSiteSettings()]);return <div className="site-width control-layout">{c.userView&&<div className="view-banner full-row"><div><strong>Test mode: regular user.</strong> Your real account remains the protected sysadmin.</div><form action={exitUserViewAction}><button className="button" type="submit">Return to sysadmin</button></form></div>}<aside className="control-sidebar"><div className="control-title">User dashboard</div><div className="control-user">{c.profile.display_name||`@${c.profile.username}`}<small>@{c.profile.username}</small></div><nav><Link href="/dashboard">Overview</Link><Link href="/dashboard/articles">My contributions</Link>{settings.articleCreationEnabled&&<Link href="/dashboard/articles/new">Create article</Link>}<Link href="/dashboard/media">My media</Link><Link href="/dashboard/watchlist">Watchlist</Link><Link href="/dashboard/notifications">Notifications</Link><Link href="/dashboard/profile">Profile settings</Link><Link href="/dashboard/security">Account security</Link>{c.isStaff&&!c.userView&&<Link href="/admin">Administration</Link>}</nav></aside><section className="control-content">{children}</section></div>}
