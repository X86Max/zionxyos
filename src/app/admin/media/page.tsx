/* eslint-disable @next/next/no-img-element -- Media previews come from runtime Supabase Storage URLs that are not known at build time. */
import Link from "next/link";
import { Flash } from "@/components/Flash";
import { requireSysadmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { retireMediaAction } from "@/actions/media";
import { formatBytes, formatDate } from "@/lib/utils";

type UsageRow = { media_asset_id: string; article_uses: number; revision_uses: number };

export const metadata = { title: "Media Library · Administration" };

export default async function AdminMediaPage({ searchParams }: { searchParams: Promise<{ error?: string; success?: string }> }) {
  await requireSysadmin();
  const messages = await searchParams;
  const supabase = await createClient();
  const [{ data: assets }, { data: usageRows }] = await Promise.all([
    supabase.from("media_assets").select("*").order("created_at", { ascending: false }).limit(500),
    supabase.rpc("sysadmin_media_usage_counts"),
  ]);
  const ownerIds = [...new Set((assets || []).map((asset) => asset.owner_id))];
  const { data: profiles } = ownerIds.length ? await supabase.from("profiles").select("id,username").in("id", ownerIds) : { data: [] };
  const owners = new Map((profiles || []).map((profile) => [profile.id, profile.username]));
  const usage = new Map(((usageRows || []) as UsageRow[]).map((row) => [row.media_asset_id, row]));

  return <>
    <header className="classic-page-heading"><h1>Media Library</h1><p>Images and videos uploaded to Supabase Storage, including where each asset is currently referenced.</p></header>
    <Flash error={messages.error} success={messages.success} />
    <div className="wiki-message"><strong>Deletion safety:</strong> an asset with article or revision usage cannot be retired. This protects current pages and revision history from broken media references.</div>
    {!assets?.length ? <div className="wiki-message">The Media Library is empty.</div> : <table className="management-table media-table">
      <thead><tr><th>Preview</th><th>File</th><th>Uploader</th><th>Size</th><th>Usage</th><th>Created</th><th>Status</th><th>Manage</th></tr></thead>
      <tbody>{assets.map((asset) => {
        const counts = usage.get(asset.id) || { media_asset_id: asset.id, article_uses: 0, revision_uses: 0 };
        const totalUsage = Number(counts.article_uses) + Number(counts.revision_uses);
        const publicUrl = supabase.storage.from(asset.bucket).getPublicUrl(asset.object_path).data.publicUrl;
        return <tr key={asset.id}>
          <td>{asset.media_kind === "image" && !asset.deleted_at ? <img className="admin-media-thumb" src={publicUrl} alt={asset.alt_text || asset.original_name} referrerPolicy="no-referrer" loading="lazy" /> : asset.media_kind === "video" && !asset.deleted_at ? <video className="admin-media-thumb" src={publicUrl} preload="metadata" muted /> : <span>{asset.media_kind}</span>}</td>
          <td><strong>{asset.original_name}</strong><div className="tiny-text">{asset.mime_type}</div><div className="tiny-text"><code>{asset.object_path}</code></div></td>
          <td><Link href={`/admin/users/${asset.owner_id}`}>@{owners.get(asset.owner_id) || "unknown"}</Link></td>
          <td>{formatBytes(Number(asset.size_bytes))}</td>
          <td><strong>{totalUsage}</strong><div className="tiny-text">{counts.article_uses} article · {counts.revision_uses} revision</div></td>
          <td>{formatDate(asset.created_at)}</td>
          <td>{asset.deleted_at ? `Retired ${formatDate(asset.deleted_at)}` : "Active"}</td>
          <td>{!asset.deleted_at && (totalUsage === 0 ? <form action={retireMediaAction}><input type="hidden" name="id" value={asset.id} /><button className="button small danger" type="submit">Retire unused asset</button></form> : <span className="tiny-text">In use — protected</span>)}</td>
        </tr>;
      })}</tbody>
    </table>}
  </>;
}
