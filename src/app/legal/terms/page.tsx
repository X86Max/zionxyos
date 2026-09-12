import Link from "next/link";
import { getPublicSiteSettings } from "@/lib/settings";

export const metadata = { title: "Terms of Use" };
export default async function TermsPage() {
  const settings = await getPublicSiteSettings();
  return <div className="site-width content-page legal-page"><header className="classic-page-heading"><h1>Terms of Use</h1><p>Policy version 2026-09-09-v1</p></header><div className="wiki-document">
    <p>These Terms govern access to and use of Zionxyos, a collaborative encyclopedia for an original fictional universe. By creating an account or contributing content, you agree to these Terms, the <Link href="/legal/privacy">Privacy Policy</Link>, and the <Link href="/legal/guidelines">Community Guidelines</Link>.</p>
    <h2>1. Accounts</h2><p>You must provide an email address you can access, keep your credentials secure, and use the service lawfully. Do not impersonate staff or another person. You are responsible for activity performed through your account.</p>
    <h2>2. Collaborative editing</h2><p>Submitted articles and revisions may be reviewed, edited, rejected, reverted, reorganized, categorized, protected, or removed by authorized staff. Publication is not guaranteed. A submitted revision does not replace the public page until it is approved.</p>
    <h2>3. Content you submit</h2><p>You retain rights you already hold in original material you submit. You grant the Zionxyos operator a non-exclusive permission to host, store, reproduce, display, format, moderate, back up, and distribute that material as reasonably necessary to operate the encyclopedia. You must have the rights or permission required to submit text, images, video, or other media.</p>
    <h2>4. Prohibited conduct</h2><p>Do not upload unlawful material, malware, deliberate spam, abusive or harassing content, material that infringes third-party rights, or content intended to compromise the service. Do not bypass moderation, access controls, rate limits, or security protections.</p>
    <h2>5. Moderation</h2><p>Zionxyos may issue warnings, restrict contributions, suspend or ban accounts, protect pages, reject revisions, or remove content when reasonably necessary to enforce these policies or protect the service. Administrative actions may be logged for accountability.</p>
    <h2>6. Service changes</h2><p>The service may be updated, placed in maintenance mode, interrupted, or discontinued. Features may change between releases. Uninterrupted availability is not guaranteed.</p>
    <h2>7. Third-party infrastructure</h2><p>Zionxyos uses third-party infrastructure for hosting, authentication, database, storage, and optional embedded media. Those providers may have their own terms and service conditions.</p>
    <h2>8. Liability</h2><p>To the extent permitted by applicable law, Zionxyos is provided on an “as available” basis. Nothing in these Terms excludes rights or liabilities that cannot legally be excluded.</p>
    <h2>9. Policy changes</h2><p>Material changes may require registered users to accept a new policy version before contributing again. The accepted version and acceptance time may be recorded.</p>
    <h2>10. Contact</h2><p>Questions may be sent to {settings.legalContactEmail ? <a href={`mailto:${settings.legalContactEmail}`}>{settings.legalContactEmail}</a> : <em>the contact address configured by the operator before public launch</em>}.</p>
    <p className="legal-disclaimer">This text is a project policy template, not legal advice. The operator should obtain qualified legal review before relying on it for formal compliance.</p>
  </div></div>;
}
