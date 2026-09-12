import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { getCanonicalSiteUrl } from "@/lib/site-url";
import { safeReturnPath } from "@/lib/utils";
import {
  createPasswordRecoveryGrant,
  PASSWORD_RECOVERY_GRANT_COOKIE,
  passwordRecoveryCookieOptions,
  isPasswordRecoveryStateValid,
  verifyPasswordRecoveryState,
} from "@/lib/password-recovery";

function authRedirect(location: string) {
  const response = NextResponse.redirect(location);
  response.headers.set("Cache-Control", "private, no-store, max-age=0");
  response.headers.set("Pragma", "no-cache");
  response.headers.set("Expires", "0");
  return response;
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const origin = getCanonicalSiteUrl();
  const code = searchParams.get("code");
  const safeNext = safeReturnPath(searchParams.get("next"), "/dashboard");
  const recoveryState = searchParams.get("recovery_state");
  const recoveryAttempt = safeNext === "/update-password";

  if (recoveryAttempt && !isPasswordRecoveryStateValid(recoveryState)) {
    return authRedirect(`${origin}/forgot-password?error=${encodeURIComponent("That password-recovery link is invalid or expired. Request a new link.")}`);
  }

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      if (recoveryAttempt) {
        const { data: userData } = await supabase.auth.getUser();
        const user = userData.user;
        if (!user?.email || !verifyPasswordRecoveryState(recoveryState, user.email)) {
          await supabase.auth.signOut();
          return authRedirect(`${origin}/forgot-password?error=${encodeURIComponent("That password-recovery link is invalid or expired.")}`);
        }
        const response = authRedirect(`${origin}/update-password`);
        response.cookies.set(PASSWORD_RECOVERY_GRANT_COOKIE, createPasswordRecoveryGrant(user.id), passwordRecoveryCookieOptions());
        return response;
      }
      return authRedirect(`${origin}${safeNext}`);
    }
  }

  return authRedirect(`${origin}/login?error=${encodeURIComponent("Authentication could not be completed.")}`);
}
