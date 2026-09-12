import { redirect } from "next/navigation";
import { cookies } from "next/headers";
import { updatePasswordAction } from "@/actions/auth";
import { Flash } from "@/components/Flash";
import { createClient } from "@/lib/supabase/server";
import { PASSWORD_RECOVERY_GRANT_COOKIE, verifyPasswordRecoveryGrant } from "@/lib/password-recovery";

export const metadata={title:"Set new password",robots:{index:false,follow:false}};
export const dynamic="force-dynamic";

export default async function UpdatePasswordPage({searchParams}:{searchParams:Promise<{error?:string}>}){
  const p=await searchParams;
  const supabase=await createClient();
  const{data:userData}=await supabase.auth.getUser();
  const jar=await cookies();
  const grant=jar.get(PASSWORD_RECOVERY_GRANT_COOKIE)?.value;
  if(!userData.user||!verifyPasswordRecoveryGrant(grant,userData.user.id))redirect(`/forgot-password?error=${encodeURIComponent("Start a new password-recovery request.")}`);
  return <section className="auth-shell"><div className="auth-card"><p className="eyebrow">ACCOUNT SECURITY</p><h1>Set a new password</h1><Flash error={p.error}/><form action={updatePasswordAction} className="stack"><label>New password<input type="password" name="password" minLength={8} autoComplete="new-password" required/></label><label>Confirm new password<input type="password" name="confirm_password" minLength={8} autoComplete="new-password" required/></label><button className="button primary" type="submit">Update password</button></form></div></section>;
}
