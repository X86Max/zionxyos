import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { submitReportAction, toggleWatchAction } from "@/actions/community";
import { Flash } from "@/components/Flash";
import { WikiArticle } from "@/components/WikiArticle";
import { getAuthContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import type { Article, InfoboxSchemaField } from "@/lib/types";
import { extractInternalTargets } from "@/lib/wiki";
import { resolveStoredMediaUrls } from "@/lib/media-server";
import { canEditArticle } from "@/lib/article-permissions";
import { getPublicSiteSettings } from "@/lib/settings";

export const dynamic = "force-dynamic";

type RelatedArticle = { id: string; title: string; slug: string; summary: string | null; shared_categories: number };

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params;
  const supabase = await createClient();
  const { data: article, error } = await supabase.from("articles").select("title,slug,summary").eq("slug", slug).eq("status", "published").is("deleted_at", null).maybeSingle();
  if (error) throw new Error("Could not load article metadata.");
  if (!article) return { title: "Article not found", robots: { index: false, follow: false } };
  const description = (article.summary || `Read ${article.title} on Zionxyos.`).slice(0, 300);
  return { title: article.title, description, alternates: { canonical: `/article/${article.slug}` }, openGraph: { type: "article", title: article.title, description } };
}

export default async function ArticlePage({ params, searchParams }: {
  params: Promise<{ slug: string }>;
  searchParams: Promise<{ error?: string; success?: string }>;
}) {
  const { slug } = await params;
  const messages = await searchParams;
  const supabase = await createClient();
  const [context, siteSettings] = await Promise.all([getAuthContext(), getPublicSiteSettings()]);
  const { data: article, error: articleError } = await supabase.from("articles").select("*").eq("slug", slug).eq("status", "published").is("deleted_at", null).maybeSingle();
  if (articleError) throw new Error("Could not load the published article.");
  if (!article) notFound();
  const renderedArticle = await resolveStoredMediaUrls(article);

  const [authorResult, watchedResult, categoryLinksResult, noticeLinksResult, typeResult] = await Promise.all([
    supabase.from("public_profiles").select("username,display_name").eq("id", article.author_id).maybeSingle(),
    context ? supabase.from("watchlist").select("article_id").eq("article_id", article.id).eq("user_id", context.user.id).maybeSingle() : Promise.resolve({ data: null }),
    supabase.from("article_categories").select("category_id").eq("article_id", article.id),
    supabase.from("article_notices").select("notice_id").eq("article_id", article.id),
    article.article_type_id ? supabase.from("article_types").select("name,infobox_schema").eq("id", article.article_type_id).maybeSingle() : Promise.resolve({ data: null }),
  ]);

  const categoryIds = (categoryLinksResult.data || []).map((row) => row.category_id);
  const [categoryRowsResult, relatedResult, noticeRowsResult] = await Promise.all([
    categoryIds.length ? supabase.from("categories").select("id,name,slug").in("id", categoryIds).eq("active", true) : Promise.resolve({ data: [] }),
    categoryIds.length ? supabase.rpc("wiki_related_articles", { article_uuid: article.id, max_results: 6 }) : Promise.resolve({ data: [] }),
    noticeLinksResult.data?.length ? supabase.from("notice_templates").select("id,body,kind").in("id", noticeLinksResult.data.map((row) => row.notice_id)).eq("active", true) : Promise.resolve({ data: [] }),
  ]);
  const related = (relatedResult.data || []) as RelatedArticle[];

  const targets = extractInternalTargets(article.content);
  const { data: linked } = targets.length ? await supabase.rpc("wiki_resolve_links", { targets }) : { data: [] };
  const internalLinks = Object.fromEntries((linked || []).map((item: { title: string; slug: string }) => [item.title.toLocaleLowerCase("en-US"), item.slug]));
  const categorySlugs = Object.fromEntries((categoryRowsResult.data || []).map((item) => [item.name, item.slug]));
  const schema = Array.isArray(typeResult.data?.infobox_schema) ? typeResult.data.infobox_schema as InfoboxSchemaField[] : [];
  const infoboxLabels = Object.fromEntries(schema.map((field) => [field.key, field.label]));
  const mayEdit = Boolean(context?.canContribute && siteSettings.articleCreationEnabled) && await canEditArticle(article.id,{regularUserView:Boolean(context?.userView)});

  return <div className="site-width article-page-shell">
    <Flash error={messages.error} success={messages.success} />
    <WikiArticle
      article={renderedArticle as Article}
      slug={article.slug}
      articleId={article.id}
      author={authorResult.data}
      updatedAt={article.updated_at}
      publishedAt={article.published_at}
      internalLinks={internalLinks}
      categorySlugs={categorySlugs}
      articleTypeName={typeResult.data?.name || null}
      infoboxLabels={infoboxLabels}
      notices={(noticeRowsResult.data || []).map((item) => ({ id: item.id, body: item.body, kind: item.kind }))}
      canEdit={mayEdit}
      watched={Boolean(watchedResult.data)}
      watchAction={context ? toggleWatchAction : undefined}
    />
    {!!related?.length && <section className="related-articles"><h2>Related articles</h2><ul>{related.map((item) => <li key={item.id}><Link href={`/article/${item.slug}`}>{item.title}</Link>{item.summary && <> — {item.summary}</>}</li>)}</ul></section>}
    {context && <details className="report-box"><summary>Report this page</summary><form action={submitReportAction} className="stack compact-form"><input type="hidden" name="target_type" value="article" /><input type="hidden" name="target_id" value={article.id} /><input type="hidden" name="return_to" value={`/article/${article.slug}`} /><label><span>Reason</span><input name="reason" required maxLength={500} /></label><label><span>Details</span><textarea name="details" rows={3} maxLength={4000} /></label><button className="button secondary" type="submit">Submit report</button></form></details>}
  </div>;
}
