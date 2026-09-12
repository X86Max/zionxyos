import crypto from "node:crypto";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";

export type RateLimitAction="register"|"login"|"password_reset"|"article_write"|"report"|"discussion"|"media_upload";

function rateLimitSalt() {
  const configured = process.env.RATE_LIMIT_SALT?.trim() || "";
  const weak = configured.length < 24 || /replace|development-only/i.test(configured);
  if (process.env.NODE_ENV === "production" && weak) {
    throw new Error("RATE_LIMIT_SALT must be a non-placeholder secret of at least 24 characters in production.");
  }
  return weak ? "zionxyos-development-only" : configured;
}

async function networkSubject(){
  const h=await headers();
  const raw=h.get("x-vercel-forwarded-for")||h.get("x-forwarded-for")||h.get("x-real-ip")||"unknown";
  const ip=raw.split(",")[0]?.trim()||"unknown";
  return crypto.createHash("sha256").update(`${rateLimitSalt()}:${ip}`).digest("hex");
}

export async function consumeRateLimit(action:RateLimitAction,maxEvents:number,windowSeconds:number,subject?:string){
  const s=await createClient();
  const{data,error}=await s.rpc("consume_rate_limit",{action_name:action,subject_key:subject||await networkSubject(),max_events:maxEvents,window_seconds:windowSeconds});
  return{allowed:!error&&Boolean(data),error:error?.message||null};
}
