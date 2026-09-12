import Link from "next/link";
import { notFound,redirect } from "next/navigation";
import { ArticleForm } from "@/components/ArticleForm";
import { Flash } from "@/components/Flash";
import { adminUpdatePendingRevisionAction } from "@/actions/admin";
import { requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { loadEditorData } from "@/lib/editor";
import { formatDate } from "@/lib/utils";
import type { ArticleRevision } from "@/lib/types";
import { canEditArticle } from "@/lib/article-permissions";
export const metadata={title:"Edit revision · Administration"};
export default async function AdminEdit({params,searchParams}:{params:Promise<{id:string}>;searchParams:Promise<{error?:string;success?:string}>}){const c=await requireAdmin();const{id}=await params;const m=await searchParams;const s=await createClient();const{data:r}=await s.from("article_revisions").select("*").eq("id",id).maybeSingle();if(!r)notFound();if(r.status!=="pending_review")redirect(`/admin/review/${id}?error=${encodeURIComponent("This revision is no longer pending review.")}`);if(!(await canEditArticle(r.article_id)))redirect(`/admin/review/${id}?error=${encodeURIComponent("Page protection does not permit this administrator to edit the revision.")}`);const{data:author}=await s.from("profiles").select("username,display_name").eq("id",r.author_id).maybeSingle();const editor=await loadEditorData({userId:c.user.id,revisionId:r.id});return <><header className="classic-page-heading action-heading"><div><h1>Edit pending revision</h1><p><Link href={`/admin/review/${r.id}`}>← Back to preview</Link> · submitted by @{author?.username||"unknown"} on {formatDate(r.submitted_at||r.created_at)}</p></div></header><Flash error={m.error} success={m.success}/><div className="wiki-message warning"><strong>You are editing the submitted revision.</strong><p>Saving here does not publish it and does not create a new revision. Return to preview to approve, request changes, or reject.</p></div><ArticleForm action={adminUpdatePendingRevisionAction} editorData={editor} article={r as ArticleRevision} revisionId={r.id} submitLabel="Save and return to preview" singleSubmit/></>}
