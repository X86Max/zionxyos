/* eslint-disable @next/next/no-img-element -- Article cover images are validated runtime media URLs whose host is not fixed at build time. */
import Link from "next/link";
import { MarkdownView } from "@/components/MarkdownView";
import { TableOfContents } from "@/components/TableOfContents";
import { VideoEmbed } from "@/components/VideoEmbed";
import { formatDate, slugify } from "@/lib/utils";
import type { Article, ArticleRevision } from "@/lib/types";
import { safeMediaUrl } from "@/lib/media-url";

type ArticleLike = Pick<
  Article,
  | "title"
  | "summary"
  | "content"
  | "article_type"
  | "category"
  | "categories"
  | "tags"
  | "cover_image_url"
  | "video_url"
  | "infobox"
  | "original_creator"
> | Pick<
  ArticleRevision,
  | "title"
  | "summary"
  | "content"
  | "article_type"
  | "category"
  | "categories"
  | "tags"
  | "cover_image_url"
  | "video_url"
  | "infobox"
  | "original_creator"
>;

type Props = {
  article: ArticleLike;
  slug?: string;
  articleId?: string;
  author?: { username: string; display_name?: string | null } | null;
  updatedAt?: string | null;
  publishedAt?: string | null;
  internalLinks?: Record<string, string>;
  categorySlugs?: Record<string, string>;
  articleTypeName?: string | null;
  infoboxLabels?: Record<string, string>;
  preview?: boolean;
  notice?: string;
  notices?: { id: string; body: string; kind: string }[];
  canEdit?: boolean;
  watched?: boolean;
  watchAction?: (formData: FormData) => Promise<void>;
};

export function WikiArticle({
  article,
  slug,
  articleId,
  author,
  updatedAt,
  publishedAt,
  internalLinks = {},
  categorySlugs = {},
  articleTypeName,
  infoboxLabels = {},
  preview = false,
  notice,
  notices = [],
  canEdit = false,
  watched = false,
  watchAction,
}: Props) {
  const categories = article.categories?.length ? article.categories : article.category ? [article.category] : [];
  const infobox = article.infobox && typeof article.infobox === "object" ? article.infobox : {};
  const typeLabel = articleTypeName || article.article_type || "Article";
  const coverImageUrl = safeMediaUrl(article.cover_image_url);

  return (
    <article className="wiki-article">
      <div className="wiki-page-tabs">
        <div className="wiki-tab-group">
          <span className="wiki-tab active">Article</span>
          {slug && <Link className="wiki-tab" href={`/article/${slug}/discussion`}>Discussion</Link>}
        </div>
        <div className="wiki-tab-group right">
          <span className="wiki-tab active">Read</span>
          {canEdit && articleId && <Link className="wiki-tab" href={`/dashboard/articles/${articleId}/edit`}>Edit</Link>}
          {slug && <Link className="wiki-tab" href={`/article/${slug}/history`}>View history</Link>}
          {watchAction && articleId && <form action={watchAction} className="tab-form"><input type="hidden" name="article_id" value={articleId} /><input type="hidden" name="slug" value={slug || ""} /><button className="wiki-tab tab-button" type="submit">{watched ? "★ Watching" : "☆ Watch"}</button></form>}
        </div>
      </div>

      {notice ? <div className="preview-ribbon">{notice}</div> : preview ? <div className="preview-ribbon">PREVIEW — this revision is not published yet</div> : null}
      {notices.map((item) => <div className={`article-notice notice-${item.kind}`} key={item.id}>{item.body}</div>)}

      <header className="wiki-article-header">
        <h1>{article.title}</h1>
        <div className="wiki-subtitle">{typeLabel} on Zionxyos</div>
      </header>

      {article.summary && <p className="article-lead">{article.summary}</p>}

      <div className="wiki-article-body">
        {(Object.keys(infobox).length > 0 || coverImageUrl || article.original_creator) && <aside className="infobox">
          <div className="infobox-title">{article.title}</div>
          {coverImageUrl && <div className="infobox-image-wrap"><img className="infobox-image" src={coverImageUrl} alt={article.title} referrerPolicy="no-referrer" loading="lazy" /></div>}
          <table><tbody>
            {Object.entries(infobox).map(([key, value]) => <tr key={key}><th>{infoboxLabels[key] || key.replaceAll("_", " ")}</th><td>{String(value)}</td></tr>)}
            {article.original_creator && <tr><th>Original concept creator</th><td>{article.original_creator}</td></tr>}
          </tbody></table>
        </aside>}
        <TableOfContents content={article.content} />
        <MarkdownView content={article.content} internalLinks={internalLinks} />
        <VideoEmbed url={article.video_url} />
      </div>

      {!!categories.length && <div className="category-box"><strong>Categories:</strong>{" "}{categories.map((category, index) => <span key={category}>{index > 0 && " · "}<Link href={`/categories/${categorySlugs[category] || slugify(category)}`}>{category}</Link></span>)}</div>}
      {!!article.tags?.length && <div className="article-tags"><strong>Tags:</strong> {article.tags.join(" · ")}</div>}

      <footer className="article-footer-meta">
        <div>{author && <>Article created by <Link href={`/u/${author.username}`}>@{author.username}</Link>. </>}{publishedAt && <>Published {formatDate(publishedAt)}. </>}{updatedAt && <>Last updated {formatDate(updatedAt)}.</>}</div>
        {slug && <div className="article-tools"><Link href={`/article/${slug}/backlinks`}>What links here</Link> · <Link href={`/article/${slug}/history`}>Page history</Link></div>}
      </footer>
    </article>
  );
}
