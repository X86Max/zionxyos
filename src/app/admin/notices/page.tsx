import Link from "next/link";
import { requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Flash } from "@/components/Flash";
import { assignArticleNoticeAction, removeArticleNoticeAction } from "@/actions/admin";
import { deleteNoticeTemplateAction, saveNoticeTemplateAction } from "@/actions/system";
import { formatDate } from "@/lib/utils";

export const metadata = { title: "Editorial notices · Administration" };

type NoticeTemplate = {
  id: string;
  name: string;
  body: string;
  kind: "info" | "warning" | "maintenance" | "quality";
  active: boolean;
  created_at: string;
};

type ArticleRow = {
  id: string;
  title: string;
  slug: string;
  status: string;
  protection_level: "open" | "admin" | "sysadmin";
  protected_until: string | null;
  deleted_at: string | null;
};

function canManageArticle(article: ArticleRow, role: "user" | "admin" | "sysadmin") {
  if (article.deleted_at) return false;
  if (article.protected_until && new Date(article.protected_until).getTime() <= Date.now()) return true;
  if (article.protection_level === "open") return true;
  if (article.protection_level === "admin") return role === "admin" || role === "sysadmin";
  return role === "sysadmin";
}

export default async function EditorialNoticesPage({ searchParams }: { searchParams: Promise<{ error?: string; success?: string }> }) {
  const context = await requireAdmin();
  const messages = await searchParams;
  const supabase = await createClient();
  const [{ data: templates }, { data: articles }, { data: assignments }] = await Promise.all([
    supabase.from("notice_templates").select("id,name,body,kind,active,created_at").order("name"),
    supabase.from("articles").select("id,title,slug,status,protection_level,protected_until,deleted_at").eq("status", "published").is("deleted_at", null).order("title").limit(500),
    supabase.from("article_notices").select("article_id,notice_id,assigned_by,assigned_at").order("assigned_at", { ascending: false }),
  ]);

  const templateRows = (templates || []) as NoticeTemplate[];
  const articleRows = (articles || []) as ArticleRow[];
  const templateById = new Map(templateRows.map((item) => [item.id, item]));
  const articleById = new Map(articleRows.map((item) => [item.id, item]));
  const manageableArticles = articleRows.filter((article) => canManageArticle(article, context.effectiveRole));

  return <>
    <header className="classic-page-heading"><h1>Editorial notices</h1><p>Reusable page banners for stubs, sourcing problems, quality warnings, maintenance, and other editorial states.</p></header>
    <Flash error={messages.error} success={messages.success} />

    {context.effectiveRole === "sysadmin" && <section className="admin-section">
      <h2>Notice templates</h2>
      <p className="hint">Only the sysadmin can create, edit, disable, or delete templates. Disabling a template prevents new assignments and hides it from public rendering.</p>
      <details className="admin-create-box"><summary>+ Create notice template</summary>
        <form action={saveNoticeTemplateAction} className="wiki-fieldset">
          <div className="form-grid three">
            <label><span>Name</span><input name="name" required maxLength={100} /></label>
            <label><span>Kind</span><select name="kind" defaultValue="info"><option value="info">Info</option><option value="warning">Warning</option><option value="quality">Quality</option><option value="maintenance">Maintenance</option></select></label>
            <label className="check-inline"><input name="active" type="checkbox" defaultChecked /> Active</label>
          </div>
          <label><span>Banner text</span><textarea name="body" required rows={4} maxLength={1000} /></label>
          <button className="button primary" type="submit">Create template</button>
        </form>
      </details>
      {!templateRows.length ? <div className="wiki-message">No notice templates exist yet.</div> : <table className="management-table"><thead><tr><th>Template</th><th>Kind</th><th>Status</th><th>Manage</th></tr></thead><tbody>{templateRows.map((template) => <tr key={template.id}><td><strong>{template.name}</strong><div>{template.body}</div><div className="tiny-text">Created {formatDate(template.created_at)}</div></td><td>{template.kind}</td><td>{template.active ? "Active" : "Inactive"}</td><td><details><summary>Edit</summary><form action={saveNoticeTemplateAction} className="wiki-fieldset"><input type="hidden" name="id" value={template.id} /><label><span>Name</span><input name="name" defaultValue={template.name} required /></label><label><span>Kind</span><select name="kind" defaultValue={template.kind}><option value="info">Info</option><option value="warning">Warning</option><option value="quality">Quality</option><option value="maintenance">Maintenance</option></select></label><label><span>Banner text</span><textarea name="body" rows={4} defaultValue={template.body} required /></label><label className="check-inline"><input name="active" type="checkbox" defaultChecked={template.active} /> Active</label><div className="actions compact"><button className="button" type="submit">Save template</button></div></form><form action={deleteNoticeTemplateAction}><input type="hidden" name="id" value={template.id} /><button className="button small danger" type="submit">Delete if unused</button></form></details></td></tr>)}</tbody></table>}
    </section>}

    <section className="admin-section">
      <h2>Assign a notice</h2>
      <p className="hint">Admins may manage notices only on pages their MFA-backed role is allowed to edit. Sysadmin-only protected pages remain sysadmin-only.</p>
      {!templateRows.some((item) => item.active) ? <div className="wiki-message">There are no active notice templates available.</div> : !manageableArticles.length ? <div className="wiki-message">There are no published articles you can manage.</div> : <form action={assignArticleNoticeAction} className="wiki-fieldset"><div className="form-grid two"><label><span>Article</span><select name="article_id" required>{manageableArticles.map((article) => <option key={article.id} value={article.id}>{article.title}</option>)}</select></label><label><span>Notice template</span><select name="notice_id" required>{templateRows.filter((item) => item.active).map((template) => <option key={template.id} value={template.id}>{template.name}</option>)}</select></label></div><button className="button primary" type="submit">Assign notice</button></form>}
    </section>

    <section className="admin-section"><h2>Current assignments</h2>
      {!assignments?.length ? <div className="wiki-message">No editorial notices are assigned to articles.</div> : <table className="management-table"><thead><tr><th>Article</th><th>Notice</th><th>Assigned</th><th></th></tr></thead><tbody>{assignments.map((assignment) => { const article = articleById.get(assignment.article_id); const template = templateById.get(assignment.notice_id); const manageable = article ? canManageArticle(article, context.effectiveRole) : false; return <tr key={`${assignment.article_id}-${assignment.notice_id}`}><td>{article ? <Link href={`/article/${article.slug}`}>{article.title}</Link> : "Unavailable article"}</td><td>{template ? <><strong>{template.name}</strong><div className="tiny-text">{template.kind}{template.active ? "" : " · inactive"}</div></> : "Unavailable template"}</td><td>{formatDate(assignment.assigned_at)}</td><td>{manageable && <form action={removeArticleNoticeAction}><input type="hidden" name="article_id" value={assignment.article_id} /><input type="hidden" name="notice_id" value={assignment.notice_id} /><button className="button small danger" type="submit">Remove</button></form>}</td></tr>; })}</tbody></table>}
    </section>
  </>;
}
