"use client";

import { useMemo, useRef, useState } from "react";
import { DirectMediaUpload } from "@/components/DirectMediaUpload";
import { MarkdownView } from "@/components/MarkdownView";
import type { EditorData } from "@/lib/editor";


type Editable = {
  id?: string;
  article_id?: string;
  title?: string;
  summary?: string | null;
  content?: string;
  article_type?: string;
  article_type_id?: string | null;
  cover_image_url?: string | null;
  video_url?: string | null;
  cover_media_id?: string | null;
  video_media_id?: string | null;
  infobox?: Record<string, string> | null;
  original_creator?: string | null;
  edit_summary?: string | null;
};

type Props = {
  action: (formData: FormData) => Promise<void>;
  editorData: EditorData;
  article?: Editable;
  revisionId?: string;
  submitLabel?: string;
  singleSubmit?: boolean;
};

type FlatCategory = EditorData["categories"][number] & { depth: number };

function flattenCategories(categories: EditorData["categories"]): FlatCategory[] {
  const ids = new Set(categories.map((category) => category.id));
  const children = new Map<string | null, EditorData["categories"]>();

  for (const category of categories) {
    const parent = category.parent_id && ids.has(category.parent_id) ? category.parent_id : null;
    children.set(parent, [...(children.get(parent) || []), category]);
  }

  for (const rows of children.values()) {
    rows.sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));
  }

  const output: FlatCategory[] = [];
  const seen = new Set<string>();
  function walk(parent: string | null, depth: number) {
    for (const category of children.get(parent) || []) {
      if (seen.has(category.id)) continue;
      seen.add(category.id);
      output.push({ ...category, depth });
      walk(category.id, depth + 1);
    }
  }
  walk(null, 0);
  for (const category of categories) if (!seen.has(category.id)) output.push({ ...category, depth: 0 });
  return output;
}

function customKey(label: string) {
  return label
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 80);
}

export function ArticleForm({ action, editorData, article, revisionId, submitLabel, singleSubmit = false }: Props) {
  const [content, setContent] = useState(article?.content || "");
  const [uploading, setUploading] = useState(0);
  const [preview, setPreview] = useState(false);
  const [citationOpen, setCitationOpen] = useState(false);
  const textarea = useRef<HTMLTextAreaElement>(null);

  const initialType = article?.article_type_id
    || editorData.articleTypes.find((type) => type.slug === article?.article_type)?.id
    || editorData.articleTypes[0]?.id
    || "";
  const [typeId, setTypeId] = useState(initialType);
  const [infobox, setInfobox] = useState<Record<string, string>>(article?.infobox ? { ...article.infobox } : {});
  const initialSchemaKeys = new Set(editorData.articleTypes.find((type) => type.id === initialType)?.infobox_schema.map((field) => field.key) || []);
  const [customFields, setCustomFields] = useState<string[]>(Object.keys(article?.infobox || {}).filter((key) => !initialSchemaKeys.has(key)));
  const [newCustomLabel, setNewCustomLabel] = useState("");

  const [coverId, setCoverId] = useState(article?.cover_media_id || "");
  const [coverUrl, setCoverUrl] = useState(article?.cover_image_url || "");
  const [videoId, setVideoId] = useState(article?.video_media_id || "");
  const [videoUrl, setVideoUrl] = useState(article?.video_url || "");
  const [cite, setCite] = useState({ name: "", title: "", url: "", author: "", site: "", date: "", accessed: "" });

  const flatCategories = useMemo(() => flattenCategories(editorData.categories), [editorData.categories]);
  const activeType = editorData.articleTypes.find((type) => type.id === typeId);
  const schema = activeType?.infobox_schema || [];
  const imageAssets = editorData.mediaAssets.filter((asset) => asset.media_kind === "image");
  const videoAssets = editorData.mediaAssets.filter((asset) => asset.media_kind === "video");

  function insert(before: string, after = "", placeholder = "text") {
    const element = textarea.current;
    if (!element) return;
    const start = element.selectionStart;
    const end = element.selectionEnd;
    const selected = content.slice(start, end) || placeholder;
    const next = content.slice(0, start) + before + selected + after + content.slice(end);
    setContent(next);
    requestAnimationFrame(() => {
      element.focus();
      const cursor = start + before.length + selected.length + after.length;
      element.setSelectionRange(cursor, cursor);
    });
  }

  function insertLine(prefix: string, placeholder: string) {
    const element = textarea.current;
    if (!element) return;
    const start = content.lastIndexOf("\n", Math.max(0, element.selectionStart - 1)) + 1;
    const nextLine = content.indexOf("\n", element.selectionStart);
    const end = nextLine < 0 ? content.length : nextLine;
    setContent(content.slice(0, start) + prefix + (content.slice(start, end) || placeholder) + content.slice(end));
    requestAnimationFrame(() => element.focus());
  }

  function addCitation() {
    const parts = (Object.entries(cite) as Array<[keyof typeof cite, string]>)
      .filter(([, value]) => value.trim())
      .map(([key, value]) => `${key}=${value.trim()}`);
    if (!parts.length) return;
    insert(`{{cite|${parts.join("|")}}}`, "", "");
    setCitationOpen(false);
  }

  function chooseMedia(kind: "image" | "video", id: string) {
    const asset = (kind === "image" ? imageAssets : videoAssets).find((item) => item.id === id);
    if (kind === "image") {
      setCoverId(id);
      setCoverUrl(asset?.public_url || "");
    } else {
      setVideoId(id);
      setVideoUrl(asset?.public_url || "");
    }
  }

  function changeType(nextTypeId: string) {
    const nextSchema = new Set(editorData.articleTypes.find((type) => type.id === nextTypeId)?.infobox_schema.map((field) => field.key) || []);
    const previousSchema = new Set(schema.map((field) => field.key));
    const preserved = new Set(customFields);
    for (const key of previousSchema) if (!nextSchema.has(key) && infobox[key]) preserved.add(key);
    for (const key of nextSchema) preserved.delete(key);
    setCustomFields([...preserved]);
    setTypeId(nextTypeId);
  }

  function addCustomField() {
    const key = customKey(newCustomLabel);
    if (!key) return;
    if (schema.some((field) => field.key === key) || customFields.includes(key)) return;
    setCustomFields([...customFields, key]);
    setInfobox({ ...infobox, [key]: "" });
    setNewCustomLabel("");
  }

  function removeCustomField(key: string) {
    const next = { ...infobox };
    delete next[key];
    setInfobox(next);
    setCustomFields(customFields.filter((field) => field !== key));
  }

  if (!editorData.articleTypes.length) {
    return <div className="wiki-message warning"><strong>No active article types exist.</strong><p>The sysadmin must create at least one article type before articles can be written.</p></div>;
  }

  return (
    <form
      action={action}
      className="editor-form"
      onSubmit={(event) => {
        if (uploading > 0) {
          event.preventDefault();
          window.alert("Wait for the media upload to finish before saving this revision.");
        }
      }}
    >
      {article?.id && <input type="hidden" name="id" value={article.article_id || article.id} />}
      {revisionId && <input type="hidden" name="revision_id" value={revisionId} />}
      <input type="hidden" name="article_type_id" value={typeId} />
      <input type="hidden" name="infobox_json" value={JSON.stringify(infobox)} />
      <input type="hidden" name="cover_media_id" value={coverId} />
      <input type="hidden" name="video_media_id" value={videoId} />
      <input type="hidden" name="upload_in_progress" value={uploading > 0 ? "1" : "0"} />

      <fieldset className="wiki-fieldset">
        <legend>Page identity</legend>
        <div className="form-grid two">
          <label><span>Title</span><input name="title" required maxLength={160} defaultValue={article?.title || ""} /></label>
          <label><span>Article type</span><select value={typeId} onChange={(event) => changeType(event.target.value)}>{editorData.articleTypes.map((type) => <option key={type.id} value={type.id}>{type.name}</option>)}</select></label>
        </div>
        {activeType?.description && <p className="hint">{activeType.description}</p>}
        <label><span>Summary</span><textarea name="summary" rows={3} maxLength={600} defaultValue={article?.summary || ""} placeholder="A short encyclopedia summary used in listings and search results." /></label>
        <label><span>Original creator of the subject</span><input name="original_creator" maxLength={200} defaultValue={article?.original_creator || ""} placeholder="Creator of this fictional concept, if applicable" /></label>
      </fieldset>

      <fieldset className="wiki-fieldset">
        <legend>Categories and controlled tags</legend>
        {!flatCategories.length ? <p className="hint">No categories have been created yet.</p> : <div className="taxonomy-picker">{flatCategories.map((category) => <label className="taxonomy-option" key={category.id} style={{ paddingLeft: `${8 + category.depth * 20}px` }}><input type="checkbox" name="category_ids" value={category.id} defaultChecked={editorData.selectedCategoryIds.includes(category.id)} /><span>{category.depth ? "↳ " : ""}{category.name}</span></label>)}</div>}
        {!editorData.tags.length ? <p className="hint">No controlled tags have been created yet.</p> : <div className="tag-picker">{editorData.tags.map((tag) => <label className="tag-choice" key={tag.id}><input type="checkbox" name="tag_ids" value={tag.id} defaultChecked={editorData.selectedTagIds.includes(tag.id)} /> {tag.name}</label>)}</div>}
        <p className="hint">Contributors can select existing taxonomy. Only the sysadmin can create, rename, move, disable, or delete article types, categories, subcategories, and controlled tags.</p>
      </fieldset>

      <fieldset className="wiki-fieldset">
        <legend>Media</legend>
        <div className="form-grid two media-editor-grid">
          <div>
            <label><span>Infobox image URL</span><input type="url" name="cover_image_url" value={coverUrl} onChange={(event) => { setCoverUrl(event.target.value); setCoverId(""); }} placeholder="https://..." /></label>
            {imageAssets.length > 0 && <label><span>Or choose from your Media Library</span><select value={coverId} onChange={(event) => chooseMedia("image", event.target.value)}><option value="">External URL / none</option>{imageAssets.map((asset) => <option key={asset.id} value={asset.id}>{asset.original_name}</option>)}</select></label>}
            <DirectMediaUpload kind="image" maxBytes={editorData.upload.maxImageBytes} enabled={editorData.upload.enabled && editorData.upload.imageEnabled} onAsset={(asset) => { setCoverId(asset.id); setCoverUrl(asset.public_url); }} onBusyChange={(busy) => setUploading((count) => Math.max(0, count + (busy ? 1 : -1)))} />
          </div>
          <div>
            <label><span>Video URL</span><input type="url" name="video_url" value={videoUrl} onChange={(event) => { setVideoUrl(event.target.value); setVideoId(""); }} placeholder="YouTube, Vimeo, or a direct media URL" /></label>
            {videoAssets.length > 0 && <label><span>Or choose from your Media Library</span><select value={videoId} onChange={(event) => chooseMedia("video", event.target.value)}><option value="">External URL / none</option>{videoAssets.map((asset) => <option key={asset.id} value={asset.id}>{asset.original_name}</option>)}</select></label>}
            <DirectMediaUpload kind="video" maxBytes={editorData.upload.maxVideoBytes} enabled={editorData.upload.enabled && editorData.upload.videoEnabled} onAsset={(asset) => { setVideoId(asset.id); setVideoUrl(asset.public_url); }} onBusyChange={(busy) => setUploading((count) => Math.max(0, count + (busy ? 1 : -1)))} />
          </div>
        </div>
      </fieldset>

      <fieldset className="wiki-fieldset">
        <legend>Infobox</legend>
        {schema.length === 0 ? <p className="hint">This article type has no predefined infobox fields.</p> : <div className="infobox-builder">{schema.map((field) => <label key={field.key}><span>{field.label}{field.required ? " *" : ""}</span><input required={Boolean(field.required)} value={infobox[field.key] || ""} placeholder={field.placeholder || ""} onChange={(event) => setInfobox({ ...infobox, [field.key]: event.target.value.slice(0, 500) })} /></label>)}</div>}
        {customFields.length > 0 && <div className="custom-infobox-fields"><h3>Custom fields</h3>{customFields.map((key) => <div className="custom-infobox-row" key={key}><label><span>{key.replaceAll("_", " ")}</span><input value={infobox[key] || ""} onChange={(event) => setInfobox({ ...infobox, [key]: event.target.value.slice(0, 500) })} /></label><button className="button small danger" type="button" onClick={() => removeCustomField(key)}>Remove</button></div>)}</div>}
        <div className="inline-form custom-field-add"><input value={newCustomLabel} maxLength={80} onChange={(event) => setNewCustomLabel(event.target.value)} placeholder="Custom field label" /><button className="button secondary" type="button" onClick={addCustomField}>+ Add custom field</button></div>
      </fieldset>

      <fieldset className="wiki-fieldset editor-fieldset">
        <legend>Content</legend>
        <div className="editor-tabs"><button type="button" className={!preview ? "active" : ""} onClick={() => setPreview(false)}>Edit source</button><button type="button" className={preview ? "active" : ""} onClick={() => setPreview(true)}>Preview</button></div>
        {preview ? <div className="editor-preview"><MarkdownView content={content || "*Nothing to preview yet.*"} /></div> : <>
          <div className="editor-toolbar">
            <button type="button" onClick={() => insert("**", "**", "bold text")}><strong>B</strong></button>
            <button type="button" onClick={() => insert("*", "*", "italic text")}><em>I</em></button>
            <button type="button" onClick={() => insertLine("## ", "Section")}>H2</button>
            <button type="button" onClick={() => insertLine("### ", "Subsection")}>H3</button>
            <button type="button" onClick={() => insert("[[", "]]", "Page name")}>Internal link</button>
            <button type="button" onClick={() => insert("[", "](https://example.com)", "link text")}>External link</button>
            <button type="button" onClick={() => insertLine("- ", "item")}>List</button>
            <button type="button" onClick={() => insertLine("> ", "quote")}>Quote</button>
            <button type="button" onClick={() => setCitationOpen((value) => !value)}>Reference [1]</button>
          </div>
          {citationOpen && <div className="citation-builder"><strong>Insert reference</strong><p className="hint">The citation becomes a numbered marker such as [1] and is collected automatically in References.</p><div className="form-grid three">{Object.keys(cite).map((key) => <label key={key}><span>{key[0].toUpperCase() + key.slice(1)}</span><input value={cite[key as keyof typeof cite]} onChange={(event) => setCite({ ...cite, [key]: event.target.value })} /></label>)}</div><div className="actions compact"><button className="button" type="button" onClick={addCitation}>Insert citation</button><button className="button secondary" type="button" onClick={() => setCitationOpen(false)}>Cancel</button></div></div>}
          <textarea ref={textarea} className="editor source-editor" name="content" rows={28} value={content} onChange={(event) => setContent(event.target.value)} placeholder={"Write the article in Markdown.\n\n## First section\n\nText begins here."} />
          <p className="hint">Internal links use <code>[[Page name]]</code> or <code>[[Page name|display text]]</code>.</p>
        </>}
      </fieldset>

      <fieldset className="wiki-fieldset"><legend>Edit summary</legend><label><span>What changed?</span><input name="edit_summary" maxLength={300} defaultValue={article?.edit_summary || ""} placeholder="Briefly describe this contribution" /></label></fieldset>

      <div className="editor-submit-bar">
        {singleSubmit ? <button className="button primary" type="submit" disabled={uploading > 0}>{submitLabel || "Save review changes"}</button> : <div className="actions compact"><button className="button secondary" type="submit" name="intent" value="draft" disabled={uploading > 0}>Save draft</button><button className="button primary" type="submit" name="intent" value="review" disabled={uploading > 0}>Submit for review</button></div>}
        {uploading > 0 && <span className="hint">Waiting for {uploading} upload{uploading === 1 ? "" : "s"}…</span>}
      </div>
    </form>
  );
}
