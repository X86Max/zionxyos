import { createClient } from "@/lib/supabase/server";

type StoredMediaRow = { id:string; bucket:string; object_path:string; media_kind:"image"|"video"; deleted_at:string|null };

type MediaBackedRecord = {
  cover_image_url?: string | null;
  video_url?: string | null;
  cover_media_id?: string | null;
  video_media_id?: string | null;
};

export async function resolveStoredMediaUrls<T extends MediaBackedRecord>(record: T): Promise<T> {
  const ids = [record.cover_media_id, record.video_media_id].filter((id): id is string => Boolean(id));
  if (!ids.length) return record;
  const supabase = await createClient();
  const { data } = await supabase
    .from("media_assets")
    .select("id,bucket,object_path,media_kind,deleted_at")
    .in("id", ids)
    .is("deleted_at", null);
  const byId = new Map<string, StoredMediaRow>(((data || []) as StoredMediaRow[]).map((asset) => [asset.id, asset]));
  let cover = record.cover_media_id ? null : record.cover_image_url || null;
  let video = record.video_media_id ? null : record.video_url || null;

  if (record.cover_media_id) {
    const asset = byId.get(record.cover_media_id);
    if (asset?.media_kind === "image") cover = supabase.storage.from(asset.bucket).getPublicUrl(asset.object_path).data.publicUrl;
  }
  if (record.video_media_id) {
    const asset = byId.get(record.video_media_id);
    if (asset?.media_kind === "video") video = supabase.storage.from(asset.bucket).getPublicUrl(asset.object_path).data.publicUrl;
  }
  return { ...record, cover_image_url: cover, video_url: video };
}
