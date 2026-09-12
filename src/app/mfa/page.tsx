import { redirect } from "next/navigation";
import { getAuthContext } from "@/lib/auth";
import { MfaPanel } from "@/components/MfaPanel";

export const metadata = { title: "Multi-factor authentication" };

export default async function MfaPage() {
  const context = await getAuthContext();
  if (!context) redirect("/login");
  if (context.blocked) redirect("/suspended");
  if (!context.legalAccepted) redirect("/legal/accept");
  if (!context.isStaff || context.userView) redirect("/dashboard");
  if (context.hasAal2) redirect("/admin");
  return <div className="site-width content-page narrow-page">
    <header className="classic-page-heading"><h1>Multi-factor authentication</h1><p>Administrative access requires an AAL2 session protected by a TOTP authenticator.</p></header>
    <div className="wiki-message warning"><strong>Staff security requirement</strong><p>Enroll or verify your authenticator before opening Administration.</p></div>
    <MfaPanel />
  </div>;
}
