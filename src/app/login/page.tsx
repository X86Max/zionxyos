import Link from "next/link";
import { loginAction } from "@/actions/auth";
import { Flash } from "@/components/Flash";
import { getPublicSiteSettings } from "@/lib/settings";
export const metadata={title:"Sign in"};
export default async function LoginPage({searchParams}:{searchParams:Promise<{error?:string;success?:string}>}){const p=await searchParams;const settings=await getPublicSiteSettings();return <section className="auth-shell"><div className="auth-card"><p className="eyebrow">ZIONXYOS ACCOUNT</p><h1>Sign in</h1><Flash error={p.error} success={p.success}/><form action={loginAction} className="stack"><label>Email<input type="email" name="email" autoComplete="email" required/></label><label>Password<input type="password" name="password" autoComplete="current-password" required/></label><button className="button primary" type="submit">Sign in</button></form><div className="auth-links"><Link href="/forgot-password">Forgot your password?</Link>{settings.registrationEnabled&&<Link href="/register">Create account</Link>}</div></div></section>}
