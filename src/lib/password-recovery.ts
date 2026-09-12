import crypto from "node:crypto";

export const PASSWORD_RECOVERY_GRANT_COOKIE = "zionxyos_password_recovery";
const STATE_TTL_SECONDS = 20 * 60;
const GRANT_TTL_SECONDS = 15 * 60;

type SignedPayload = {
  v: 1;
  purpose: "password_recovery_state" | "password_recovery_grant";
  exp: number;
  nonce: string;
  email_hash?: string;
  user_id?: string;
};

function recoverySecret() {
  const configured = process.env.AUTH_RECOVERY_STATE_SECRET?.trim() || "";
  const weak = configured.length < 32 || /replace|development-only|placeholder/i.test(configured);
  if (process.env.NODE_ENV === "production" && weak) {
    throw new Error("AUTH_RECOVERY_STATE_SECRET must be a non-placeholder secret of at least 32 characters in production.");
  }
  return weak ? "zionxyos-development-only-password-recovery-secret" : configured;
}

function emailHash(email: string) {
  return crypto.createHash("sha256").update(email.trim().toLocaleLowerCase("en-US")).digest("base64url");
}

function sign(payload: SignedPayload) {
  const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
  const signature = crypto.createHmac("sha256", recoverySecret()).update(encoded).digest("base64url");
  return `${encoded}.${signature}`;
}

function verify(raw: string | null | undefined, purpose: SignedPayload["purpose"]) {
  if (!raw || raw.length > 2048) return null;
  const [encoded, signature, extra] = raw.split(".");
  if (!encoded || !signature || extra) return null;
  const expected = crypto.createHmac("sha256", recoverySecret()).update(encoded).digest();
  let supplied: Buffer;
  try { supplied = Buffer.from(signature, "base64url"); } catch { return null; }
  if (supplied.length !== expected.length || !crypto.timingSafeEqual(supplied, expected)) return null;
  try {
    const payload = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")) as SignedPayload;
    if (payload.v !== 1 || payload.purpose !== purpose || !Number.isInteger(payload.exp) || payload.exp < Math.floor(Date.now() / 1000)) return null;
    if (!/^[A-Za-z0-9_-]{16,128}$/.test(payload.nonce || "")) return null;
    return payload;
  } catch { return null; }
}

export function createPasswordRecoveryState(email: string) {
  return sign({
    v: 1,
    purpose: "password_recovery_state",
    email_hash: emailHash(email),
    nonce: crypto.randomBytes(18).toString("base64url"),
    exp: Math.floor(Date.now() / 1000) + STATE_TTL_SECONDS,
  });
}

export function verifyPasswordRecoveryState(raw: string | null | undefined, email: string) {
  const payload = verify(raw, "password_recovery_state");
  return Boolean(payload?.email_hash && payload.email_hash === emailHash(email));
}

export function isPasswordRecoveryStateValid(raw: string | null | undefined) {
  return Boolean(verify(raw, "password_recovery_state")?.email_hash);
}


export function createPasswordRecoveryGrant(userId: string) {
  return sign({
    v: 1,
    purpose: "password_recovery_grant",
    user_id: userId,
    nonce: crypto.randomBytes(18).toString("base64url"),
    exp: Math.floor(Date.now() / 1000) + GRANT_TTL_SECONDS,
  });
}

export function verifyPasswordRecoveryGrant(raw: string | null | undefined, userId: string) {
  const payload = verify(raw, "password_recovery_grant");
  return Boolean(payload?.user_id && payload.user_id === userId);
}

export function passwordRecoveryCookieOptions() {
  return {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax" as const,
    path: "/update-password",
    maxAge: GRANT_TTL_SECONDS,
  };
}
