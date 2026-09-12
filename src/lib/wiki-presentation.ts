import { createClient } from "@/lib/supabase/server";
import type { InfoboxSchemaField } from "@/lib/types";

export async function loadWikiPresentation(options: {
  articleTypeId?: string | null;
  articleId?: string;
  revisionId?: string;
}) {
  const supabase = await createClient();
  const typePromise = options.articleTypeId
    ? supabase.from("article_types").select("name,infobox_schema").eq("id", options.articleTypeId).maybeSingle()
    : Promise.resolve({ data: null });
  const relationPromise = options.revisionId
    ? supabase.from("revision_categories").select("category_id").eq("revision_id", options.revisionId)
    : options.articleId
      ? supabase.from("article_categories").select("category_id").eq("article_id", options.articleId)
      : Promise.resolve({ data: [] });

  const [typeResult, relationResult] = await Promise.all([typePromise, relationPromise]);
  const categoryIds = (relationResult.data || []).map((row) => row.category_id);
  const categoryResult = categoryIds.length
    ? await supabase.from("categories").select("id,name,slug").in("id", categoryIds)
    : { data: [] as { id: string; name: string; slug: string }[] };
  const schema = Array.isArray(typeResult.data?.infobox_schema)
    ? typeResult.data.infobox_schema as InfoboxSchemaField[]
    : [];

  return {
    articleTypeName: typeResult.data?.name || null,
    infoboxLabels: Object.fromEntries(schema.map((field) => [field.key, field.label])),
    categorySlugs: Object.fromEntries((categoryResult.data || []).map((category) => [category.name, category.slug])),
  };
}
