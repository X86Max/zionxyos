import Link from "next/link";
import { redirect } from "next/navigation";
import { acceptLegalAction } from "@/actions/auth";
import { Flash } from "@/components/Flash";
import { getAuthContext } from "@/lib/auth";
export const metadata={title:"Policy acceptance"};
export default async function LegalAcceptPage({searchParams}:{searchParams:Promise<{error?:string}>}){const m=await searchParams;const c=await getAuthContext();if(!c)redirect("/login");if(c.blocked)redirect("/suspended");if(c.legalAccepted)redirect("/dashboard");return <div className="site-width content-page narrow-page"><header className="classic-page-heading"><h1>Review the current policies</h1><p>Existing accounts must accept the current policy version before contributing.</p></header><Flash error={m.error}/><div className="wiki-message warning"><p>Please read the <Link href="/legal/terms">Terms of Use</Link>, <Link href="/legal/privacy">Privacy Policy</Link>, and <Link href="/legal/guidelines">Community Guidelines</Link>.</p></div><form action={acceptLegalAction} className="wiki-fieldset stack"><label className="check-inline"><input type="checkbox" name="legal_acceptance" required/> I have read and agree to the current Terms, Privacy Policy, and Community Guidelines.</label><button className="button primary" type="submit">Accept and continue</button></form></div>}
