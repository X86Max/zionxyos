import Link from "next/link";
import { changeEmailAction, changePasswordAction, signOutOtherSessionsAction } from "@/actions/auth";
import { Flash } from "@/components/Flash";
import { requireUser } from "@/lib/auth";

export const metadata = { title: "Account security" };

export default async function AccountSecurityPage({ searchParams }: { searchParams: Promise<{ error?: string; success?: string }> }) {
  const context = await requireUser();
  const messages = await searchParams;
  return <>
    <header className="classic-page-heading"><h1>Account security</h1><p>Manage credentials and authenticated sessions for @{context.profile.username}.</p></header>
    <Flash error={messages.error} success={messages.success} />

    <section className="admin-section security-section">
      <h2>Change password</h2>
      <p className="hint">Your current password is required before a normal signed-in password change.</p>
      <form action={changePasswordAction} className="wiki-fieldset stack narrow-form">
        <label><span>Current password</span><input type="password" name="current_password" required autoComplete="current-password" /></label>
        <label><span>New password</span><input type="password" name="password" required minLength={8} autoComplete="new-password" /></label>
        <label><span>Confirm new password</span><input type="password" name="confirm_password" required minLength={8} autoComplete="new-password" /></label>
        <button className="button primary" type="submit">Change password</button>
      </form>
    </section>

    <section className="admin-section security-section">
      <h2>Change email address</h2>
      <p className="hint">Current email: <strong>{context.user.email || "Unavailable"}</strong>. Confirmation behavior follows the Supabase Auth configuration for this project.</p>
      <form action={changeEmailAction} className="inline-form narrow-form">
        <input type="email" name="email" required autoComplete="email" placeholder="new-address@example.com" />
        <button className="button" type="submit">Request email change</button>
      </form>
    </section>

    <section className="admin-section security-section">
      <h2>Other sessions</h2>
      <p>Invalidate refresh-token sessions on other browsers and devices while keeping this session active.</p>
      <form action={signOutOtherSessionsAction}><button className="button warning-button" type="submit">Sign out other sessions</button></form>
      <p className="hint">Already-issued access tokens may remain usable until they expire; revoked sessions cannot refresh them.</p>
    </section>

    {context.isStaff && !context.userView && <section className="admin-section security-section"><h2>Administrative MFA</h2><p>Administrative pages require an AAL2 session. If this browser is not currently verified, open the MFA flow.</p><Link href="/mfa" className="button">Open MFA verification</Link></section>}
  </>;
}
