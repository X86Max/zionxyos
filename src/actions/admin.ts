"use server";

import { cookies } from "next/headers";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireAdmin, requireSysadmin, getAuthContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { canEditArticle } from "@/lib/article-permissions";
import { requireMediaUrl } from "@/lib/media-url";
import { safeReturnPath } from "@/lib/utils";
import type { ModerationKind, UserRole } from "@/lib/types";



function idList(formData: FormData, key: string) {
  return [...new Set(formData.getAll(key).map(String).filter((v) => /^[0-9a-f-]{36}$/i.test(v)))].slice(0, 100);
}

function parseInfoboxJson(value: FormDataEntryValue | null) {
  try {
    const raw = JSON.parse(String(value || "{}"));
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
    const out: Record<string, string> = {};
    for (const [key, value] of Object.entries(raw).slice(0, 60)) {
      const k = key.trim().slice(0, 80);
      const v = String(value ?? "").trim().slice(0, 500);
      if (k && v) out[k] = v;
    }
    return out;
  } catch { return {}; }
}

async function readRevisionFields(formData: FormData) {
  if (String(formData.get("upload_in_progress") || "") === "1") throw new Error("Wait for media uploads to finish before saving.");
  const title = String(formData.get("title") || "").trim().slice(0, 160);
  if (!title) throw new Error("Title is required.");
  const articleTypeId = String(formData.get("article_type_id") || "");
  const categoryIds = idList(formData, "category_ids");
  const tagIds = idList(formData, "tag_ids");
  const supabase = await createClient();
  const { data: type } = await supabase.from("article_types").select("id,slug").eq("id", articleTypeId).eq("active", true).maybeSingle();
  if (!type) throw new Error("The selected article type is unavailable.");
  const [cats, tags] = await Promise.all([
    categoryIds.length ? supabase.from("categories").select("id,name").in("id", categoryIds).eq("active", true) : Promise.resolve({ data: [], error: null }),
    tagIds.length ? supabase.from("controlled_tags").select("id,name").in("id", tagIds).eq("active", true) : Promise.resolve({ data: [], error: null }),
  ]);
  if (cats.error || (cats.data || []).length !== categoryIds.length) throw new Error("One or more categories are invalid or inactive.");
  if (tags.error || (tags.data || []).length !== tagIds.length) throw new Error("One or more tags are invalid or inactive.");
  const categories = (cats.data || []).map((row) => row.name);
  const coverMediaId = String(formData.get("cover_media_id") || "") || null;
  const videoMediaId = String(formData.get("video_media_id") || "") || null;
  let trustedCoverUrl: string | null = null;
  let trustedVideoUrl: string | null = null;
  for (const [mediaId, expectedKind] of [[coverMediaId, "image"], [videoMediaId, "video"]] as const) {
    if (!mediaId) continue;
    const { data: asset } = await supabase.from("media_assets").select("id,bucket,object_path,media_kind,deleted_at").eq("id", mediaId).is("deleted_at", null).maybeSingle();
    if (!asset || asset.media_kind !== expectedKind) throw new Error(`The selected ${expectedKind} asset is unavailable.`);
    if (expectedKind === "image") trustedCoverUrl = supabase.storage.from(asset.bucket).getPublicUrl(asset.object_path).data.publicUrl; else trustedVideoUrl = supabase.storage.from(asset.bucket).getPublicUrl(asset.object_path).data.publicUrl;
  }
  return {
    fields: {
      title, summary: String(formData.get("summary") || "").trim().slice(0, 600) || null,
      content: String(formData.get("content") || "").trim().slice(0, 500000),
      article_type: type.slug, article_type_id: type.id, category: categories[0] || null, categories,
      tags: (tags.data || []).map((row) => row.name),
      cover_image_url: trustedCoverUrl || requireMediaUrl(formData.get("cover_image_url")),
      video_url: trustedVideoUrl || requireMediaUrl(formData.get("video_url")),
      cover_media_id: coverMediaId,
      video_media_id: videoMediaId,
      infobox: parseInfoboxJson(formData.get("infobox_json")),
      original_creator: String(formData.get("original_creator") || "").trim().slice(0, 200) || null,
      edit_summary: String(formData.get("edit_summary") || "").trim().slice(0, 300) || null,
    }, categoryIds, tagIds,
  };
}

export async function adminUpdatePendingRevisionAction(formData: FormData) {
  await requireAdmin();
  const revisionId = String(formData.get("revision_id") || "");
  const parsed = await readRevisionFields(formData).catch((error: unknown) => {
    redirect(`/admin/review/${revisionId}/edit?error=${encodeURIComponent(error instanceof Error ? error.message : "Invalid revision data.")}`);
  });
  if (!parsed.fields.content) redirect(`/admin/review/${revisionId}/edit?error=${encodeURIComponent("Article content is required before review.")}`);
  const supabase = await createClient();
  const { data: revision } = await supabase.from("article_revisions").select("id,status,article_id").eq("id", revisionId).maybeSingle();
  if (!revision) redirect("/admin/review?error=Revision%20not%20found.");
  if (revision.status !== "pending_review") redirect(`/admin/review/${revisionId}?error=Only%20pending%20revisions%20can%20be%20edited.`);
  if (!(await canEditArticle(revision.article_id))) redirect(`/admin/review/${revisionId}?error=${encodeURIComponent("Page protection does not permit this administrator to edit the revision.")}`);
  const { error } = await supabase.from("article_revisions").update(parsed.fields).eq("id", revisionId);
  if (error) redirect(`/admin/review/${revisionId}/edit?error=${encodeURIComponent(error.message)}`);
  const [dc, dt] = await Promise.all([supabase.from("revision_categories").delete().eq("revision_id", revisionId), supabase.from("revision_tags").delete().eq("revision_id", revisionId)]);
  if (dc.error || dt.error) redirect(`/admin/review/${revisionId}/edit?error=${encodeURIComponent(dc.error?.message || dt.error?.message || "Could not update taxonomy.")}`);
  if (parsed.categoryIds.length) { const { error: e } = await supabase.from("revision_categories").insert(parsed.categoryIds.map((category_id) => ({ revision_id: revisionId, category_id }))); if (e) redirect(`/admin/review/${revisionId}/edit?error=${encodeURIComponent(e.message)}`); }
  if (parsed.tagIds.length) { const { error: e } = await supabase.from("revision_tags").insert(parsed.tagIds.map((tag_id) => ({ revision_id: revisionId, tag_id }))); if (e) redirect(`/admin/review/${revisionId}/edit?error=${encodeURIComponent(e.message)}`); }
  revalidatePath(`/admin/review/${revisionId}`);
  redirect(`/admin/review/${revisionId}?success=${encodeURIComponent("Revision updated without publishing. Review the preview before deciding.")}`);
}

export async function removeDiscussionPostAction(formData: FormData) {
  const admin = await requireAdmin();
  const postId = String(formData.get("post_id") || "");
  const slug = String(formData.get("slug") || "");
  if (!postId || !slug) redirect("/admin?error=Invalid data.");
  const returnTo=safeReturnPath(formData.get("return_to"),`/article/${encodeURIComponent(slug)}/discussion`);
  const withMessage=(key:"error"|"success",message:string)=>`${returnTo}${returnTo.includes("?")?"&":"?"}${key}=${encodeURIComponent(message)}`;

  const supabase = await createClient();
  const { error } = await supabase
    .from("discussion_posts")
    .update({ removed_at: new Date().toISOString(), removed_by: admin.user.id })
    .eq("id", postId);

  if (error) redirect(withMessage("error",error.message));
  revalidatePath(`/article/${slug}/discussion`);
  redirect(withMessage("success","Post removed by the administration."));
}

export async function enterUserViewAction() {
  await requireSysadmin();
  const store = await cookies();
  store.set("zionxyos_view", "user", {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: 60 * 60 * 8,
  });
  redirect("/dashboard");
}

export async function exitUserViewAction() {
  const context = await getAuthContext();
  if (!context || context.actualRole !== "sysadmin") redirect("/login");
  const store = await cookies();
  store.delete("zionxyos_view");
  redirect("/admin");
}

export async function setUserRoleAction(formData: FormData) {
  const admin = await requireSysadmin();
  const targetId = String(formData.get("user_id") || "");
  const role = String(formData.get("role") || "") as UserRole;

  if (!["user", "admin"].includes(role)) redirect("/admin/users?error=Only%20user%20and%20admin%20roles%20can%20be%20assigned%20here.");
  if (targetId === admin.user.id) redirect("/admin/users?error=The%20protected%20sysadmin%20account%20cannot%20change%20its%20own%20role%20here.");

  const supabase = await createClient();
  const { data: target } = await supabase.from("profiles").select("role").eq("id", targetId).maybeSingle();
  if (!target) redirect("/admin/users?error=User%20not%20found.");
  if (target.role === "sysadmin") redirect("/admin/users?error=The%20sysadmin%20role%20is%20protected.");
  const { error } = await supabase.rpc("sysadmin_set_user_role", { target_uid: targetId, requested_role: role });
  if (error) redirect(`/admin/users?error=${encodeURIComponent(error.message)}`);

  revalidatePath("/admin/users");
  revalidatePath(`/admin/users/${targetId}`);
  redirect(`/admin/users/${targetId}?success=Role updated.`);
}

function expiryFromForm(formData: FormData) {
  const duration = String(formData.get("duration") || "permanent");
  const now = Date.now();
  const durations: Record<string, number> = {
    "1h": 60 * 60 * 1000,
    "24h": 24 * 60 * 60 * 1000,
    "7d": 7 * 24 * 60 * 60 * 1000,
    "30d": 30 * 24 * 60 * 60 * 1000,
  };
  if (duration === "custom") {
    const custom = String(formData.get("expires_at") || "").trim();
    if (!custom) throw new Error("Choose a future expiry for the custom duration.");
    const parsed = new Date(custom);
    if (!Number.isFinite(parsed.getTime()) || parsed.getTime() <= now) throw new Error("Custom moderation expiry must be a valid future date and time.");
    return parsed.toISOString();
  }
  if (duration === "permanent") return null;
  return durations[duration] ? new Date(now + durations[duration]).toISOString() : null;
}

export async function applyModerationAction(formData: FormData) {
  const admin = await requireAdmin();
  const targetId = String(formData.get("user_id") || "");
  const kind = String(formData.get("kind") || "") as ModerationKind;
  const reason = String(formData.get("reason") || "").trim().slice(0, 2000);

  if (!["warning", "mute", "suspend", "ban"].includes(kind)) {
    redirect(`/admin/users/${targetId}?error=Invalid moderation action.`);
  }
  if (!reason) redirect(`/admin/users/${targetId}?error=Enter a moderation reason.`);
  let expiresAt: string | null = null;
  try { expiresAt = kind === "warning" ? null : expiryFromForm(formData); }
  catch (error) { redirect(`/admin/users/${targetId}?error=${encodeURIComponent(error instanceof Error ? error.message : "Invalid moderation expiry.")}`); }
  if (admin.effectiveRole === "admin" && (kind === "mute" || kind === "suspend") && !expiresAt) {
    redirect(`/admin/users/${targetId}?error=${encodeURIComponent("Admins must choose a finite expiry for mutes and suspensions. Permanent blocking requires the sysadmin.")}`);
  }
  if (targetId === admin.user.id && kind !== "warning") {
    redirect(`/admin/users/${targetId}?error=You cannot block your own account.`);
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("admin_apply_moderation", {
    target_uid: targetId,
    action_kind: kind,
    action_reason: reason,
    action_expires_at: expiresAt,
  });

  if (error) redirect(`/admin/users/${targetId}?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/admin");
  revalidatePath("/admin/users");
  revalidatePath(`/admin/users/${targetId}`);
  redirect(`/admin/users/${targetId}?success=Moderation action applied.`);
}

export async function revokeModerationAction(formData: FormData) {
  await requireAdmin();
  const actionId = String(formData.get("action_id") || "");
  const targetId = String(formData.get("user_id") || "");
  const reason = String(formData.get("reason") || "").trim().slice(0, 2000);
  const supabase = await createClient();
  const { error } = await supabase.rpc("admin_revoke_moderation", {
    action_uuid: actionId,
    reason: reason || null,
  });
  if (error) redirect(`/admin/users/${targetId}?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/admin/users");
  revalidatePath(`/admin/users/${targetId}`);
  redirect(`/admin/users/${targetId}?success=Moderation action revoked.`);
}

export async function addAdminNoteAction(formData: FormData) {
  const admin = await requireAdmin();
  const targetId = String(formData.get("user_id") || "");
  const body = String(formData.get("body") || "").trim().slice(0, 4000);
  if (!body) redirect(`/admin/users/${targetId}?error=The internal note is empty.`);

  const supabase = await createClient();
  const { data: target } = await supabase.from("profiles").select("role").eq("id", targetId).maybeSingle();
  if (!target) redirect(`/admin/users/${targetId}?error=User%20not%20found.`);
  if (admin.effectiveRole === "admin" && target.role !== "user") redirect(`/admin/users/${targetId}?error=${encodeURIComponent("Admins may add internal notes only to regular-user accounts.")}`);
  const { error } = await supabase.from("admin_user_notes").insert({
    user_id: targetId,
    body,
    created_by: admin.user.id,
  });
  if (error) redirect(`/admin/users/${targetId}?error=${encodeURIComponent(error.message)}`);
  revalidatePath(`/admin/users/${targetId}`);
  redirect(`/admin/users/${targetId}?success=Internal note added.`);
}

export async function reviewRevisionAction(formData: FormData) {
  await requireAdmin();
  const revisionId = String(formData.get("revision_id") || "");
  const articleId = String(formData.get("article_id") || "");
  const decision = String(formData.get("decision") || "");
  const note = String(formData.get("note") || "").trim().slice(0, 4000);

  if (!["approve", "changes_requested", "reject"].includes(decision)) {
    redirect(`/admin/review/${revisionId}?error=Invalid review decision.`);
  }
  if ((decision === "changes_requested" || decision === "reject") && !note) {
    redirect(`/admin/review/${revisionId}?error=A review note is required for this decision.`);
  }

  const supabase = await createClient();
  const { data: article } = await supabase.from("articles").select("slug").eq("id", articleId).single();
  if (!(await canEditArticle(articleId))) redirect(`/admin/review/${revisionId}?error=${encodeURIComponent("Page protection does not permit this administrator to review this revision.")}`);
  const { error } = await supabase.rpc("admin_review_revision", {
    revision_uuid: revisionId,
    decision,
    note: note || null,
  });

  if (error) redirect(`/admin/review/${revisionId}?error=${encodeURIComponent(error.message)}`);

  revalidatePath("/");
  revalidatePath("/admin");
  revalidatePath("/admin/review");
  revalidatePath("/admin/articles");
  revalidatePath("/dashboard/articles");
  if (article?.slug) revalidatePath(`/article/${article.slug}`);
  redirect(`/admin/review?success=${encodeURIComponent(decision === "approve" ? "Revision approved and published." : decision === "changes_requested" ? "Changes requested from the contributor." : "Revision rejected.")}`);
}

export async function setProtectionAction(formData: FormData) {
  const admin = await requireAdmin();
  const articleId = String(formData.get("article_id") || "");
  const level = String(formData.get("protection_level") || "open");
  const reason = String(formData.get("protection_reason") || "").trim().slice(0, 2000);
  const untilRaw = String(formData.get("protected_until") || "");
  if (!["open", "admin", "sysadmin"].includes(level)) redirect("/admin/articles?error=Invalid%20protection%20level.");
  if (level === "sysadmin" && admin.effectiveRole !== "sysadmin") redirect("/admin/articles?error=Only%20the%20sysadmin%20can%20apply%20sysadmin-only%20protection.");
  if (level !== "open" && !reason) redirect(`/admin/articles?error=${encodeURIComponent("A protection reason is required.")}`);

  let protectedUntil: string | null = null;
  if (level !== "open" && untilRaw) {
    const parsed = new Date(untilRaw);
    if (!Number.isFinite(parsed.getTime()) || parsed.getTime() <= Date.now()) redirect(`/admin/articles?error=${encodeURIComponent("Protection expiry must be a valid future date and time.")}`);
    protectedUntil = parsed.toISOString();
  }
  const supabase = await createClient();
  const { error } = await supabase.from("articles").update({
    protection_level: level,
    protection_reason: level === "open" ? null : reason || null,
    protected_until: protectedUntil,
  }).eq("id", articleId);

  if (error) redirect(`/admin/articles?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/admin/articles");
  redirect("/admin/articles?success=Protection updated.");
}

export async function toggleFeaturedAction(formData: FormData) {
  await requireAdmin();
  const articleId = String(formData.get("article_id") || "");
  const featured = String(formData.get("featured")) === "true";
  const supabase = await createClient();
  const { error } = await supabase.from("articles").update({ featured }).eq("id", articleId);
  if (error) redirect(`/admin/articles?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/");
  revalidatePath("/admin/articles");
  redirect("/admin/articles?success=Featured status updated.");
}


export async function retireArticleAction(formData: FormData) {
  await requireSysadmin();
  const articleId = String(formData.get("article_id") || "");
  const reason = String(formData.get("reason") || "").trim().slice(0, 2000);
  if (!articleId) redirect("/admin/articles?error=Missing%20article%20ID.");
  if (!reason) redirect(`/admin/articles?error=${encodeURIComponent("A retirement reason is required.")}`);
  const supabase = await createClient();
  const { data: slug, error } = await supabase.rpc("sysadmin_set_article_retired", { article_uuid: articleId, retire: true, reason });
  if (error) redirect(`/admin/articles?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/"); revalidatePath("/admin/articles"); revalidatePath("/search");
  if (slug) revalidatePath(`/article/${slug}`);
  redirect(`/admin/articles?success=${encodeURIComponent("Article retired. Its revision history is preserved.")}`);
}

export async function restoreArticleAction(formData: FormData) {
  await requireSysadmin();
  const articleId = String(formData.get("article_id") || "");
  const reason = String(formData.get("reason") || "").trim().slice(0, 2000);
  if (!articleId) redirect("/admin/articles?error=Missing%20article%20ID.");
  if (!reason) redirect(`/admin/articles?error=${encodeURIComponent("A restore reason is required.")}`);
  const supabase = await createClient();
  const { data: slug, error } = await supabase.rpc("sysadmin_set_article_retired", { article_uuid: articleId, retire: false, reason });
  if (error) redirect(`/admin/articles?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/"); revalidatePath("/admin/articles"); revalidatePath("/search");
  if (slug) revalidatePath(`/article/${slug}`);
  redirect(`/admin/articles?success=${encodeURIComponent("Article restored.")}`);
}

export async function resolveReportAction(formData: FormData) {
  const admin = await requireAdmin();
  const reportId = String(formData.get("report_id") || "");
  const status = String(formData.get("status") || "");
  const note = String(formData.get("resolution_note") || "").trim().slice(0, 4000);
  if (!["reviewing", "resolved", "dismissed"].includes(status)) redirect("/admin/reports?error=Invalid status.");

  const supabase = await createClient();
  const { error } = await supabase.from("reports").update({
    status,
    reviewed_by: admin.user.id,
    reviewed_at: status === "reviewing" ? null : new Date().toISOString(),
    resolution_note: note || null,
  }).eq("id", reportId);
  if (error) redirect(`/admin/reports?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/admin");
  revalidatePath("/admin/reports");
  redirect("/admin/reports?success=Report updated.");
}

export async function assignArticleNoticeAction(formData: FormData) {
  const context = await requireAdmin();
  const articleId = String(formData.get("article_id") || "");
  const noticeId = String(formData.get("notice_id") || "");
  if (!/^[0-9a-f-]{36}$/i.test(articleId) || !/^[0-9a-f-]{36}$/i.test(noticeId)) {
    redirect(`/admin/notices?error=${encodeURIComponent("Choose a valid article and notice template.")}`);
  }
  const supabase = await createClient();
  const [{ data: canEdit, error: capabilityError }, { data: template, error: templateError }, { data: article }] = await Promise.all([
    supabase.rpc("can_edit_article", { article_uuid: articleId }),
    supabase.from("notice_templates").select("id,active").eq("id", noticeId).eq("active", true).maybeSingle(),
    supabase.from("articles").select("slug").eq("id", articleId).maybeSingle(),
  ]);
  if (capabilityError || canEdit !== true) redirect(`/admin/notices?error=${encodeURIComponent("Page protection does not permit you to manage notices for this article.")}`);
  if (templateError || !template) redirect(`/admin/notices?error=${encodeURIComponent("The selected notice template is inactive or unavailable.")}`);
  const { error } = await supabase.from("article_notices").insert({ article_id: articleId, notice_id: noticeId, assigned_by: context.user.id });
  if (error) redirect(`/admin/notices?error=${encodeURIComponent(error.code === "23505" ? "That notice is already assigned to the article." : error.message)}`);
  revalidatePath("/admin/notices");
  if (article?.slug) revalidatePath(`/article/${article.slug}`);
  redirect(`/admin/notices?success=${encodeURIComponent("Editorial notice assigned.")}`);
}

export async function removeArticleNoticeAction(formData: FormData) {
  await requireAdmin();
  const articleId = String(formData.get("article_id") || "");
  const noticeId = String(formData.get("notice_id") || "");
  if (!/^[0-9a-f-]{36}$/i.test(articleId) || !/^[0-9a-f-]{36}$/i.test(noticeId)) redirect("/admin/notices?error=Invalid%20notice%20assignment.");
  const supabase = await createClient();
  const [{ data: canEdit, error: capabilityError }, { data: article }] = await Promise.all([
    supabase.rpc("can_edit_article", { article_uuid: articleId }),
    supabase.from("articles").select("slug").eq("id", articleId).maybeSingle(),
  ]);
  if (capabilityError || canEdit !== true) redirect(`/admin/notices?error=${encodeURIComponent("Page protection does not permit you to manage notices for this article.")}`);
  const { error } = await supabase.from("article_notices").delete().eq("article_id", articleId).eq("notice_id", noticeId);
  if (error) redirect(`/admin/notices?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/admin/notices");
  if (article?.slug) revalidatePath(`/article/${article.slug}`);
  redirect(`/admin/notices?success=${encodeURIComponent("Editorial notice removed.")}`);
}
