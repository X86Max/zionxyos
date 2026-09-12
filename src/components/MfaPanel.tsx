/* eslint-disable @next/next/no-img-element -- Supabase supplies the TOTP QR code as runtime enrollment image data. */
"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type TotpFactor = { id: string; friendly_name?: string; status?: string };

export function MfaPanel() {
  const supabase = useMemo(() => createClient(), []);
  const router = useRouter();
  const [factor, setFactor] = useState<TotpFactor | null>(null);
  const [qr, setQr] = useState("");
  const [secret, setSecret] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("Checking authenticator status…");

  useEffect(() => {
    let alive = true;
    void (async () => {
      const { data, error } = await supabase.auth.mfa.listFactors();
      if (!alive) return;
      if (error) return setMessage(error.message);
      const verified = data.totp.find((item) => item.status === "verified");
      if (verified) {
        setFactor(verified);
        setMessage("Enter the six-digit code from your authenticator app to continue.");
      } else {
        setMessage("No verified authenticator is enrolled yet.");
      }
    })();
    return () => { alive = false; };
  }, [supabase]);

  async function enroll() {
    setBusy(true);
    setMessage("Preparing authenticator enrollment…");
    const { data: factors, error: listError } = await supabase.auth.mfa.listFactors();
    if (listError) { setBusy(false); return setMessage(listError.message); }
    for (const stale of factors.totp.filter((item) => item.status !== "verified")) {
      const { error: cleanupError } = await supabase.auth.mfa.unenroll({ factorId: stale.id });
      if (cleanupError) { setBusy(false); return setMessage(`Could not clear an unfinished authenticator enrollment: ${cleanupError.message}`); }
    }
    setMessage("Creating authenticator enrollment…");
    const { data, error } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: "Zionxyos administration" });
    setBusy(false);
    if (error) return setMessage(error.message);
    setFactor(data);
    setQr(data.totp.qr_code);
    setSecret(data.totp.secret);
    setMessage("Scan the QR code, then enter the current six-digit code below.");
  }

  async function verify() {
    if (!factor || !/^\d{6}$/.test(code)) return setMessage("Enter a valid six-digit authenticator code.");
    setBusy(true);
    setMessage("Verifying…");
    const { data: challenge, error: challengeError } = await supabase.auth.mfa.challenge({ factorId: factor.id });
    if (challengeError) { setBusy(false); return setMessage(challengeError.message); }
    const { error } = await supabase.auth.mfa.verify({ factorId: factor.id, challengeId: challenge.id, code });
    setBusy(false);
    if (error) return setMessage(error.message);
    setMessage("MFA verified. Redirecting…");
    router.push("/admin");
    router.refresh();
  }

  return <div className="mfa-panel">
    <p>{message}</p>
    {!factor && <button className="button primary" type="button" disabled={busy} onClick={enroll}>Enroll authenticator</button>}
    {qr && <div className="mfa-enrollment"><img src={qr} className="mfa-qr" alt="TOTP enrollment QR code" /><p><strong>Manual setup secret:</strong> <code className="break-all">{secret}</code></p></div>}
    {factor && <div className="mfa-verify"><label><span>Authenticator code</span><input inputMode="numeric" autoComplete="one-time-code" value={code} maxLength={6} onChange={(event) => setCode(event.target.value.replace(/\D/g, "").slice(0, 6))} /></label><button className="button primary" type="button" disabled={busy} onClick={verify}>Verify</button></div>}
  </div>;
}
