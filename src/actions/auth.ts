"use server";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { consumeRateLimit } from "@/lib/rate-limit";
import { getCanonicalSiteUrl } from "@/lib/site-url";
import { cookies } from "next/headers";
import { createPasswordRecoveryState, PASSWORD_RECOVERY_GRANT_COOKIE, passwordRecoveryCookieOptions, verifyPasswordRecoveryGrant } from "@/lib/password-recovery";
const msg=(p:string,k:"error"|"success",m:string)=>`${p}?${k}=${encodeURIComponent(m)}`;
const RESERVED_USERNAMES=new Set(["admin","administrator","root","sysadmin","system","support","moderator","staff","zionxyos","api","security","help"]);
export async function loginAction(f:FormData){const email=String(f.get("email")||"").trim();const password=String(f.get("password")||"");if(!email||!password)redirect(msg("/login","error","Enter your email address and password."));const limit=await consumeRateLimit("login",12,900);if(!limit.allowed)redirect(msg("/login","error","Too many sign-in attempts. Try again later."));const s=await createClient();const{error}=await s.auth.signInWithPassword({email,password});if(error)redirect(msg("/login","error","The email address or password is incorrect."));redirect("/dashboard");}
export async function registerAction(f:FormData){const username=String(f.get("username")||"").trim().toLowerCase();const email=String(f.get("email")||"").trim();const password=String(f.get("password")||"");const confirm=String(f.get("confirm_password")||"");if(!/^[a-z0-9_]{3,24}$/.test(username))redirect(msg("/register","error","Username must contain 3–24 lowercase letters, numbers, or underscores."));if(RESERVED_USERNAMES.has(username))redirect(msg("/register","error","That username is reserved by Zionxyos. Choose another username."));if(!email)redirect(msg("/register","error","Enter an email address."));if(password.length<8)redirect(msg("/register","error","Use a password with at least 8 characters."));if(password!==confirm)redirect(msg("/register","error","The passwords do not match."));if(f.get("legal_acceptance")!=="on")redirect(msg("/register","error","You must accept the Terms, Privacy Policy, and Community Guidelines."));const limit=await consumeRateLimit("register",5,3600);if(!limit.allowed)redirect(msg("/register","error","Too many registration attempts. Try again later."));const s=await createClient();const[{data:reg},{data:existing}]=await Promise.all([s.from("site_settings").select("value").eq("key","registration_enabled").maybeSingle(),s.from("public_profiles").select("id").eq("username",username).maybeSingle()]);if(reg?.value===false)redirect(msg("/register","error","Registration is currently disabled."));if(existing)redirect(msg("/register","error","That username is already in use."));const{data:v,error:ve}=await s.rpc("current_legal_versions");if(ve||!v?.length)redirect(msg("/register","error","The current legal policy version could not be verified."));const legal=v[0];const site=getCanonicalSiteUrl();const{error}=await s.auth.signUp({email,password,options:{emailRedirectTo:`${site}/auth/callback?next=/dashboard`,data:{username,legal_acceptance:"true",terms_version:legal.terms_version,privacy_version:legal.privacy_version,guidelines_version:legal.guidelines_version}}});if(error)redirect(msg("/register","error",error.message));redirect(msg("/login","success","Account created. If email confirmation is enabled, confirm your email before signing in."));}
export async function acceptLegalAction(f:FormData){if(f.get("legal_acceptance")!=="on")redirect(msg("/legal/accept","error","You must explicitly accept the current Terms, Privacy Policy, and Community Guidelines."));const s=await createClient();const{data}=await s.auth.getUser();if(!data.user)redirect("/login");const{error}=await s.rpc("accept_current_legal",{source_name:"reconsent"});if(error)redirect(msg("/legal/accept","error",error.message));redirect("/dashboard");}
export async function forgotPasswordAction(f:FormData){const email=String(f.get("email")||"").trim().slice(0,320);if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))redirect(msg("/forgot-password","error","Enter a valid email address."));const limit=await consumeRateLimit("password_reset",5,3600);if(!limit.allowed)redirect(msg("/forgot-password","error","Too many recovery requests. Try again later."));const s=await createClient();const site=getCanonicalSiteUrl();const state=createPasswordRecoveryState(email);const{error}=await s.auth.resetPasswordForEmail(email,{redirectTo:`${site}/auth/callback?next=/update-password&recovery_state=${encodeURIComponent(state)}`});if(error)redirect(msg("/forgot-password","error",error.message));redirect(msg("/forgot-password","success","If an account exists for that address, a recovery link will be sent."));}
export async function updatePasswordAction(f:FormData){const p=String(f.get("password")||"");const c=String(f.get("confirm_password")||"");if(p.length<8)redirect(msg("/update-password","error","Use a password with at least 8 characters."));if(p!==c)redirect(msg("/update-password","error","The passwords do not match."));const s=await createClient();const{data:userData}=await s.auth.getUser();if(!userData.user)redirect(msg("/forgot-password","error","Start a new password-recovery request."));const jar=await cookies();const grant=jar.get(PASSWORD_RECOVERY_GRANT_COOKIE)?.value;if(!verifyPasswordRecoveryGrant(grant,userData.user.id))redirect(msg("/forgot-password","error","That password-recovery authorization is missing or expired. Request a new link."));const{error}=await s.auth.updateUser({password:p});if(error)redirect(msg("/update-password","error",error.message));jar.set(PASSWORD_RECOVERY_GRANT_COOKIE,"",{...passwordRecoveryCookieOptions(),maxAge:0});await s.auth.signOut({scope:"others"});redirect(msg("/dashboard","success","Password updated. Other refresh-token sessions were signed out."));}
export async function logoutAction(){const s=await createClient();await s.auth.signOut();redirect("/");}

export async function changePasswordAction(f: FormData) {
  const currentPassword = String(f.get("current_password") || "");
  const password = String(f.get("password") || "");
  const confirm = String(f.get("confirm_password") || "");
  if (!currentPassword) redirect(msg("/dashboard/security", "error", "Enter your current password."));
  if (password.length < 8) redirect(msg("/dashboard/security", "error", "Use a new password with at least 8 characters."));
  if (password !== confirm) redirect(msg("/dashboard/security", "error", "The new passwords do not match."));
  if (password === currentPassword) redirect(msg("/dashboard/security", "error", "Choose a new password that differs from your current password."));
  const s = await createClient();
  const { data: userData } = await s.auth.getUser();
  if (!userData.user) redirect("/login");
  const { error } = await s.auth.updateUser({ password, current_password: currentPassword });
  if (error) redirect(msg("/dashboard/security", "error", error.message));
  redirect(msg("/dashboard/security", "success", "Password updated."));
}

export async function changeEmailAction(f: FormData) {
  const email = String(f.get("email") || "").trim().slice(0, 320);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) redirect(msg("/dashboard/security", "error", "Enter a valid email address."));
  const s = await createClient();
  const { data: userData } = await s.auth.getUser();
  if (!userData.user) redirect("/login");
  if (userData.user.email?.toLocaleLowerCase("en-US") === email.toLocaleLowerCase("en-US")) redirect(msg("/dashboard/security", "error", "That is already your account email address."));
  const { error } = await s.auth.updateUser({ email });
  if (error) redirect(msg("/dashboard/security", "error", error.message));
  redirect(msg("/dashboard/security", "success", "Email change requested. Follow the confirmation instructions sent by Supabase Auth."));
}

export async function signOutOtherSessionsAction() {
  const s = await createClient();
  const { data: userData } = await s.auth.getUser();
  if (!userData.user) redirect("/login");
  const { error } = await s.auth.signOut({ scope: "others" });
  if (error) redirect(msg("/dashboard/security", "error", error.message));
  redirect(msg("/dashboard/security", "success", "Other refresh-token sessions were signed out. Your current session remains active."));
}
