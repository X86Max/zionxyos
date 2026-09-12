import Link from "next/link";
import { forgotPasswordAction } from "@/actions/auth";
import { Flash } from "@/components/Flash";
export const metadata={title:"Password recovery"};
export default async function ForgotPasswordPage({searchParams}:{searchParams:Promise<{error?:string;success?:string}>}){const p=await searchParams;return <section className="auth-shell"><div className="auth-card"><p className="eyebrow">ACCOUNT RECOVERY</p><h1>Forgot your password?</h1><Flash error={p.error} success={p.success}/><form action={forgotPasswordAction} className="stack"><label>Email<input type="email" name="email" autoComplete="email" required/></label><button className="button primary" type="submit">Send recovery link</button></form><div className="auth-links"><Link href="/login">Back to sign in</Link></div></div></section>}
