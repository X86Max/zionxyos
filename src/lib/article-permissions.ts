import { createClient } from "@/lib/supabase/server";

export async function canEditArticle(articleId: string, options: { regularUserView?: boolean } = {}) {
  const supabase = await createClient();
  if (options.regularUserView) {
    const { data: article, error } = await supabase
      .from("articles")
      .select("protection_level,protected_until,deleted_at")
      .eq("id", articleId)
      .maybeSingle();
    if (error || !article || article.deleted_at) return false;
    if (article.protection_level === "open") return true;
    return Boolean(article.protected_until && new Date(article.protected_until).getTime() <= Date.now());
  }
  const { data, error } = await supabase.rpc("can_edit_article", { article_uuid: articleId });
  return !error && data === true;
}
