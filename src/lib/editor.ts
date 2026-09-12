import { createClient } from "@/lib/supabase/server";
import { getPublicSiteSettings } from "@/lib/settings";
import type { ArticleType, Category, ControlledTag, MediaAsset } from "@/lib/types";

export type EditorData = {
  articleTypes: ArticleType[];
  categories: Category[];
  tags: ControlledTag[];
  mediaAssets: MediaAsset[];
  selectedCategoryIds: string[];
  selectedTagIds: string[];
  upload: {
    enabled: boolean;
    imageEnabled: boolean;
    videoEnabled: boolean;
    maxImageBytes: number;
    maxVideoBytes: number;
  };
};

export async function loadEditorData(options: { userId: string; articleId?: string; revisionId?: string }): Promise<EditorData> {
  const supabase = await createClient();
  // Regular contributors need only public feature/limit settings. Private release
  // configuration remains inaccessible outside the sysadmin settings panel.
  const settings = await getPublicSiteSettings();
  const [types, categories, tags, media] = await Promise.all([
    supabase.from("article_types").select("id,name,slug,description,infobox_schema,active,sort_order").eq("active", true).order("sort_order").order("name"),
    supabase.from("categories").select("id,name,slug,description,parent_id,active,sort_order").eq("active", true).order("sort_order").order("name"),
    supabase.from("controlled_tags").select("id,name,slug,description,active,sort_order").eq("active", true).order("sort_order").order("name"),
    supabase.from("media_assets").select("*").eq("owner_id", options.userId).is("deleted_at", null).order("created_at", { ascending: false }).limit(100),
  ]);

  let selectedCategoryIds: string[] = [];
  let selectedTagIds: string[] = [];
  if (options.revisionId) {
    const [selectedCategories, selectedTags] = await Promise.all([
      supabase.from("revision_categories").select("category_id").eq("revision_id", options.revisionId),
      supabase.from("revision_tags").select("tag_id").eq("revision_id", options.revisionId),
    ]);
    selectedCategoryIds = (selectedCategories.data || []).map((row) => row.category_id);
    selectedTagIds = (selectedTags.data || []).map((row) => row.tag_id);
  } else if (options.articleId) {
    const [selectedCategories, selectedTags] = await Promise.all([
      supabase.from("article_categories").select("category_id").eq("article_id", options.articleId),
      supabase.from("article_tags").select("tag_id").eq("article_id", options.articleId),
    ]);
    selectedCategoryIds = (selectedCategories.data || []).map((row) => row.category_id);
    selectedTagIds = (selectedTags.data || []).map((row) => row.tag_id);
  }

  const mediaAssets = ((media.data || []) as MediaAsset[]).map((asset) => ({
    ...asset,
    // Never trust the client-writable metadata URL as the canonical URL. Rebuild
    // it from the registered bucket/object path every time assets enter the editor.
    public_url: supabase.storage.from(asset.bucket).getPublicUrl(asset.object_path).data.publicUrl,
  }));

  return {
    articleTypes: (types.data || []) as ArticleType[],
    categories: (categories.data || []) as Category[],
    tags: (tags.data || []) as ControlledTag[],
    mediaAssets,
    selectedCategoryIds,
    selectedTagIds,
    upload: {
      enabled: settings.mediaUploadsEnabled,
      imageEnabled: settings.imageUploadsEnabled,
      videoEnabled: settings.videoUploadsEnabled,
      maxImageBytes: settings.maxImageBytes,
      maxVideoBytes: settings.maxVideoBytes,
    },
  };
}
