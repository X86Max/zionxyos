import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { APP_VERSION } from "@/lib/version";

export const dynamic = "force-dynamic";

export async function GET() {
  const started = Date.now();
  try {
    const supabase = await createClient();
    const { error } = await supabase.from("site_settings").select("key").eq("key", "site_name").maybeSingle();
    if (error) throw error;
    return NextResponse.json({ status: "ok", version: APP_VERSION, database: "reachable", latency_ms: Date.now() - started }, { headers: { "Cache-Control": "no-store" } });
  } catch {
    return NextResponse.json({ status: "degraded", version: APP_VERSION, database: "unreachable", latency_ms: Date.now() - started }, { status: 503, headers: { "Cache-Control": "no-store" } });
  }
}
