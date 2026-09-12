"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireContributor, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { safeReturnPath } from "@/lib/utils";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function validUuid(value: string) { return UUID.test(value); }

function returnMessage(path:string,key:"error"|"success",message:string){const separator=path.includes("?")?"&":"?";return `${path}${separator}${key}=${encodeURIComponent(message)}`;}

export async function toggleWatchAction(formData: FormData) {
  const context = await requireUser();
  const articleId = String(formData.get("article_id") || "");
  if (!validUuid(articleId)) return;
  const supabase = await createClient();
  const { data: existing } = await supabase.from("watchlist").select("article_id").eq("user_id", context.user.id).eq("article_id", articleId).maybeSingle();
  if (existing) {
    await supabase.from("watchlist").delete().eq("user_id", context.user.id).eq("article_id", articleId);
    revalidatePath("/dashboard/watchlist");
    return;
  }
  const { data: article } = await supabase.from("articles").select("id,slug").eq("id", articleId).eq("status", "published").is("deleted_at", null).maybeSingle();
  if (!article) return;
  await supabase.from("watchlist").insert({ user_id: context.user.id, article_id: article.id });
  revalidatePath(`/article/${article.slug}`);
  revalidatePath("/dashboard/watchlist");
}

export async function addDiscussionPostAction(formData: FormData) {
  const context = await requireContributor();
  const articleId = String(formData.get("article_id") || "");
  const suppliedSlug = String(formData.get("slug") || "").slice(0, 160);
  const fallback = suppliedSlug ? `/article/${encodeURIComponent(suppliedSlug)}/discussion` : "/";
  const body = String(formData.get("body") || "").trim().slice(0, 10000);
  const parentId = String(formData.get("parent_id") || "") || null;
  if (!validUuid(articleId)) redirect(`${fallback}?error=${encodeURIComponent("Invalid article.")}`);
  if (parentId && !validUuid(parentId)) redirect(`${fallback}?error=${encodeURIComponent("Invalid parent discussion post.")}`);
  if (!body) redirect(`${fallback}?error=${encodeURIComponent("Write a message.")}`);

  const supabase = await createClient();
  const [{ data: setting }, { data: article }] = await Promise.all([
    supabase.from("site_settings").select("value").eq("key", "discussion_enabled").maybeSingle(),
    supabase.from("articles").select("id,slug").eq("id", articleId).eq("status", "published").is("deleted_at", null).maybeSingle(),
  ]);
  if (!article) redirect(`${fallback}?error=${encodeURIComponent("The article is no longer publicly available.")}`);
  const canonicalPath = `/article/${article.slug}/discussion`;
  if (setting?.value === false) redirect(`${canonicalPath}?error=${encodeURIComponent("Discussions are currently disabled.")}`);

  if (parentId) {
    const { data: parent } = await supabase.from("discussion_posts").select("id,article_id,removed_at").eq("id", parentId).eq("article_id", article.id).maybeSingle();
    if (!parent || parent.removed_at) redirect(`${canonicalPath}?error=${encodeURIComponent("The parent discussion post is unavailable.")}`);
  }

  const { error } = await supabase.from("discussion_posts").insert({ article_id: article.id, user_id: context.user.id, parent_id: parentId, body });
  if (error) redirect(returnMessage(canonicalPath,"error",error.message));
  const { count } = await supabase.from("discussion_posts").select("id",{count:"exact",head:true}).eq("article_id",article.id);
  const lastPage=Math.max(1,Math.ceil((count||1)/100));
  const destination=lastPage>1?`${canonicalPath}?page=${lastPage}`:canonicalPath;
  revalidatePath(canonicalPath);
  redirect(returnMessage(destination,"success","Message posted."));
}

export async function submitReportAction(formData: FormData) {
  const context = await requireUser();
  const type = String(formData.get("target_type") || "");
  const id = String(formData.get("target_id") || "");
  const reason = String(formData.get("reason") || "").trim().slice(0, 500);
  const details = String(formData.get("details") || "").trim().slice(0, 4000);
  const returnTo = safeReturnPath(formData.get("return_to"));
  if (!(["article", "revision", "user", "discussion"] as const).includes(type as "article" | "revision" | "user" | "discussion")) redirect(returnMessage(returnTo,"error","Invalid report type."));
  if (!validUuid(id)) redirect(returnMessage(returnTo,"error","Invalid report target."));
  if (!reason) redirect(returnMessage(returnTo,"error","Enter a report reason."));
  const supabase = await createClient();
  const { data: targetExists, error: targetError } = await supabase.rpc("is_valid_report_target", { target_kind: type, target_uuid: id });
  if (targetError || targetExists !== true) redirect(returnMessage(returnTo,"error","The reported target is no longer publicly available."));

  const { error } = await supabase.from("reports").insert({ reporter_id: context.user.id, target_type: type, target_id: id, reason, details: details || null });
  if (error) redirect(returnMessage(returnTo,"error",error.message));
  revalidatePath("/admin/reports");
  redirect(returnMessage(returnTo,"success","Report sent to the administration."));
}

export async function markNotificationReadAction(formData: FormData) {
  await requireUser();
  const id = Number(formData.get("notification_id"));
  const href = safeReturnPath(formData.get("href"), "/dashboard/notifications");
  if (!Number.isSafeInteger(id) || id <= 0) redirect(href);
  const supabase = await createClient();
  await supabase.rpc("mark_notification_read", { notification_id: id });
  revalidatePath("/dashboard/notifications");
  redirect(href);
}
