import Link from "next/link";
import { getPublicSiteSettings } from "@/lib/settings";
export const metadata={title:"Maintenance"};
export default async function MaintenancePage(){const s=await getPublicSiteSettings();return <div className="maintenance-page"><div className="maintenance-box"><div className="maintenance-wordmark">{s.siteName}</div><h1>Maintenance in progress</h1><p>The encyclopedia is temporarily unavailable while system maintenance is being performed.</p><p>Please check back shortly.</p><div className="maintenance-staff">Administrative staff may <Link href="/login">sign in</Link>.</div></div></div>}
