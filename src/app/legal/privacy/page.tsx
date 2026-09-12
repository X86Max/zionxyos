import Link from "next/link";
import { getPublicSiteSettings } from "@/lib/settings";

export const metadata = { title: "Privacy Policy" };
export default async function PrivacyPage() {
  const settings = await getPublicSiteSettings();
  return <div className="site-width content-page legal-page"><header className="classic-page-heading"><h1>Privacy Policy</h1><p>Policy version 2026-09-09-v1</p></header><div className="wiki-document">
    <p>This policy explains how Zionxyos processes information when you browse the encyclopedia, create an account, contribute content, or use community and moderation features. It was written with Brazilian data-protection principles, including the LGPD, in mind.</p>
    <h2>1. Information processed</h2><p>Depending on your use, Zionxyos may process your email address, username, public profile text, authentication identifiers, policy-acceptance records, contributions and revision history, reports, discussions, watchlist entries, uploaded-media metadata, moderation records, administrative audit logs, and technical information needed to operate and protect the service.</p>
    <h2>2. Purposes</h2><p>Information is used to authenticate users, operate collaborative editing, preserve attribution, provide community features, enforce rules, investigate abuse, protect the service, maintain records and backups, and comply with applicable obligations.</p>
    <h2>3. Public information</h2><p>Published articles, public discussions, usernames, selected public profile fields, and contribution attribution may be visible to anyone. Do not place private or sensitive personal information in public content unless you understand that it becomes public.</p>
    <h2>4. Infrastructure providers</h2><p>Zionxyos uses Supabase for authentication, database, and storage services and Vercel as the intended application hosting platform. Those providers process technical data as needed to provide their services.</p>
    <h2>5. External media</h2><p>Articles may contain images or videos loaded from external HTTPS sources and embeds from providers such as YouTube or Vimeo. Loading that content can cause your browser to connect directly to the provider and disclose normal request information such as your IP address, browser information, referrer information, and request time.</p>
    <h2>6. Security and logs</h2><p>Zionxyos uses authentication, Row Level Security, rate limiting, audit logging, and multi-factor authentication for privileged accounts. No internet service can guarantee absolute security. Security records may be retained when reasonably necessary to investigate incidents or abuse.</p>
    <h2>7. Retention</h2><p>Account and contribution data may be retained while needed for the service. Revision, attribution, and moderation records may need to remain to protect encyclopedia integrity, prevent abuse, or handle disputes. Data no longer required should be deleted or anonymized where reasonably possible and legally appropriate.</p>
    <h2>8. Your rights</h2><p>Subject to applicable law and legitimate retention requirements, you may request information about processing, correction of inaccurate account information, deletion or anonymization where applicable, and other rights available under the LGPD.</p>
    <h2>9. Legal bases</h2><p>Depending on the activity and applicable law, processing may rely on consent, performance of the requested service, legitimate interests such as security and abuse prevention, or compliance with legal obligations.</p>
    <h2>10. Children</h2><p>Zionxyos is not intended to knowingly collect personal information from children in circumstances where parental or guardian authorization is legally required. The operator should configure age and consent practices appropriate to the audience before public launch.</p>
    <h2>11. Changes and contact</h2><p>Material policy changes may require renewed acceptance. Privacy requests may be sent to {settings.legalContactEmail ? <a href={`mailto:${settings.legalContactEmail}`}>{settings.legalContactEmail}</a> : <em>the privacy contact configured by the operator before public launch</em>}.</p>
    <p>See also the <Link href="/legal/terms">Terms of Use</Link> and <Link href="/legal/guidelines">Community Guidelines</Link>.</p>
    <p className="legal-disclaimer">This text is a project policy template, not legal advice or a guarantee of LGPD compliance. Production practices and final wording should be reviewed by a qualified professional.</p>
  </div></div>;
}
