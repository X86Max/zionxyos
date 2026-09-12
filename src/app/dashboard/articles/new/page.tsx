import { createArticleAction } from "@/actions/articles";
import { ArticleForm } from "@/components/ArticleForm";
import { Flash } from "@/components/Flash";
import { requireContributor } from "@/lib/auth";
import { loadEditorData } from "@/lib/editor";
import { getPublicSiteSettings } from "@/lib/settings";
export const metadata={title:"Create article"};
export default async function NewArticlePage({searchParams}:{searchParams:Promise<{error?:string}>}){const c=await requireContributor();const p=await searchParams;const settings=await getPublicSiteSettings();if(!settings.articleCreationEnabled)return <><header className="classic-page-heading"><h1>Create article</h1></header><div className="wiki-message warning"><strong>Article writing is temporarily disabled.</strong><p>The sysadmin has paused new submissions.</p></div></>;const editor=await loadEditorData({userId:c.user.id});return <><header className="classic-page-heading"><h1>Create a new article</h1><p>The page starts as a private draft and can be submitted to the review queue when ready.</p></header><Flash error={p.error}/><ArticleForm action={createArticleAction} editorData={editor}/></>}
