import { Flash } from "@/components/Flash";
import { InfoboxSchemaEditor } from "@/components/InfoboxSchemaEditor";
import { requireSysadmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import {
  deleteArticleTypeAction,
  deleteCategoryAction,
  deleteTagAction,
  mergeCategoryAction,
  saveArticleTypeAction,
  saveCategoryAction,
  saveTagAction,
} from "@/actions/taxonomy";
import type { ArticleType, Category, ControlledTag } from "@/lib/types";

export const metadata = { title: "Taxonomy · Administration" };

type CategoryTreeProps = { category: Category; categories: Category[]; depth?: number };

function categoryPath(categoryId: string, categories: Category[]) {
  const byId = new Map(categories.map((category) => [category.id, category]));
  const parts: string[] = [];
  const seen = new Set<string>();
  let cursor = byId.get(categoryId);
  while (cursor && !seen.has(cursor.id)) {
    seen.add(cursor.id);
    parts.unshift(cursor.name);
    cursor = cursor.parent_id ? byId.get(cursor.parent_id) : undefined;
  }
  return parts.join(" › ");
}

function descendantIds(categoryId: string, categories: Category[]) {
  const output = new Set<string>();
  const visit = (parentId: string) => {
    for (const child of categories.filter((category) => category.parent_id === parentId)) {
      if (output.has(child.id)) continue;
      output.add(child.id);
      visit(child.id);
    }
  };
  visit(categoryId);
  return output;
}

function CategoryTreeNode({ category, categories, depth = 0 }: CategoryTreeProps) {
  const children = categories
    .filter((item) => item.parent_id === category.id)
    .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));
  const descendants = descendantIds(category.id, categories);
  const mergeTargets = categories.filter((item) => item.id !== category.id && item.active && !descendants.has(item.id));

  return (
    <li className="taxonomy-tree-node">
      <details className="taxonomy-admin-item" open={depth === 0}>
        <summary>
          <span className="taxonomy-node-title">{category.name}</span>
          <small>/{category.slug} · {category.active ? "active" : "inactive"} · order {category.sort_order}</small>
        </summary>
        <div className="taxonomy-node-body">
          <div className="taxonomy-path"><strong>Path:</strong> {categoryPath(category.id, categories)}</div>
          {category.description && <p>{category.description}</p>}
          <form action={saveCategoryAction} className="wiki-fieldset taxonomy-edit-form">
            <input type="hidden" name="id" value={category.id} />
            <div className="form-grid three">
              <label><span>Name</span><input name="name" defaultValue={category.name} required maxLength={100} /></label>
              <label><span>Slug</span><input name="slug" defaultValue={category.slug} required maxLength={100} /></label>
              <label><span>Sort order</span><input name="sort_order" type="number" defaultValue={category.sort_order} /></label>
            </div>
            <label><span>Parent category</span><select name="parent_id" defaultValue={category.parent_id || ""}><option value="">None — root category</option>{categories.filter((item) => item.id !== category.id && !descendants.has(item.id)).map((item) => <option key={item.id} value={item.id}>{categoryPath(item.id, categories)}</option>)}</select></label>
            <label><span>Description</span><textarea name="description" rows={2} defaultValue={category.description || ""} /></label>
            <label className="check-inline"><input name="active" type="checkbox" defaultChecked={category.active} /> Active</label>
            <button className="button" type="submit">Save category</button>
          </form>

          <div className="taxonomy-danger-tools">
            <details>
              <summary>Merge this category into another category</summary>
              <p className="hint">Assignments move to the target, duplicates are removed, direct subcategories are reparented, and this source category is deleted. The operation is atomic and written to the audit log.</p>
              {mergeTargets.length ? (
                <form action={mergeCategoryAction} className="inline-form">
                  <input type="hidden" name="source_category_id" value={category.id} />
                  <select name="target_category_id" required defaultValue=""><option value="" disabled>Choose target category</option>{mergeTargets.map((item) => <option key={item.id} value={item.id}>{categoryPath(item.id, categories)}</option>)}</select>
                  <button className="button danger" type="submit">Merge permanently</button>
                </form>
              ) : <p className="hint">No valid active merge target is available.</p>}
            </details>
            <form action={deleteCategoryAction}><input type="hidden" name="id" value={category.id} /><button className="button small danger" type="submit">Delete only if unused</button></form>
          </div>
        </div>
      </details>
      {children.length > 0 && <ul className="taxonomy-tree-children">{children.map((child) => <CategoryTreeNode key={child.id} category={child} categories={categories} depth={depth + 1} />)}</ul>}
    </li>
  );
}

export default async function TaxonomyPage({ searchParams }: { searchParams: Promise<{ error?: string; success?: string }> }) {
  await requireSysadmin();
  const messages = await searchParams;
  const supabase = await createClient();
  const [typesResult, categoriesResult, tagsResult] = await Promise.all([
    supabase.from("article_types").select("*").order("sort_order").order("name"),
    supabase.from("categories").select("*").order("sort_order").order("name"),
    supabase.from("controlled_tags").select("*").order("sort_order").order("name"),
  ]);
  const types = (typesResult.data || []) as ArticleType[];
  const categories = (categoriesResult.data || []) as Category[];
  const tags = (tagsResult.data || []) as ControlledTag[];
  const categoryIds = new Set(categories.map((category) => category.id));
  const roots = categories
    .filter((category) => !category.parent_id || !categoryIds.has(category.parent_id))
    .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));

  return <>
    <header className="classic-page-heading"><h1>Taxonomy</h1><p>The sysadmin defines the encyclopedia structure. Zionxyos creates no fictional categories, tags, or article types by itself.</p></header>
    <Flash error={messages.error} success={messages.success} />

    <section className="admin-section">
      <h2>Article types</h2>
      <p>Article types define page semantics and the structured infobox schema. They are separate from categories.</p>
      <details className="admin-create-box"><summary>+ Create article type</summary><form action={saveArticleTypeAction} className="wiki-fieldset"><div className="form-grid three"><label><span>Name</span><input name="name" required /></label><label><span>Slug</span><input name="slug" placeholder="generated-from-name" /></label><label><span>Sort order</span><input type="number" name="sort_order" defaultValue={0} /></label></div><label><span>Description</span><textarea name="description" rows={2} /></label><label className="check-inline"><input type="checkbox" name="active" defaultChecked /> Active</label><h3>Infobox schema</h3><InfoboxSchemaEditor /><button className="button primary" type="submit">Create article type</button></form></details>
      {!types.length ? <div className="wiki-message">There are no article types yet. Create the first one before contributors start writing.</div> : types.map((type) => <details className="taxonomy-admin-item" key={type.id}><summary>{type.name} <small>/{type.slug} · {type.active ? "active" : "inactive"}</small></summary><form action={saveArticleTypeAction} className="wiki-fieldset"><input type="hidden" name="id" value={type.id} /><div className="form-grid three"><label><span>Name</span><input name="name" defaultValue={type.name} required /></label><label><span>Slug</span><input name="slug" defaultValue={type.slug} required /></label><label><span>Sort order</span><input type="number" name="sort_order" defaultValue={type.sort_order} /></label></div><label><span>Description</span><textarea name="description" rows={2} defaultValue={type.description || ""} /></label><label className="check-inline"><input type="checkbox" name="active" defaultChecked={type.active} /> Active</label><h3>Infobox schema</h3><InfoboxSchemaEditor initial={Array.isArray(type.infobox_schema) ? type.infobox_schema : []} /><button className="button" type="submit">Save article type</button></form><form action={deleteArticleTypeAction} className="taxonomy-delete-form"><input type="hidden" name="id" value={type.id} /><button className="button small danger" type="submit">Delete only if unused</button></form></details>)}
    </section>

    <section className="admin-section">
      <h2>Categories and subcategories</h2>
      <p>The tree can be nested to any practical depth. Moving a category changes the hierarchy without editing every article.</p>
      <details className="admin-create-box"><summary>+ Create category</summary><form action={saveCategoryAction} className="wiki-fieldset"><div className="form-grid three"><label><span>Name</span><input name="name" required /></label><label><span>Parent</span><select name="parent_id"><option value="">None — root category</option>{categories.map((item) => <option key={item.id} value={item.id}>{categoryPath(item.id, categories)}</option>)}</select></label><label><span>Sort order</span><input type="number" name="sort_order" defaultValue={0} /></label></div><label><span>Description</span><textarea name="description" rows={2} /></label><label className="check-inline"><input type="checkbox" name="active" defaultChecked /> Active</label><button className="button primary" type="submit">Create category</button></form></details>
      {!categories.length ? <div className="wiki-message">There are no categories yet. Create the first category.</div> : <ul className="taxonomy-tree">{roots.map((category) => <CategoryTreeNode key={category.id} category={category} categories={categories} />)}</ul>}
    </section>

    <section className="admin-section">
      <h2>Controlled tags</h2>
      <p>Contributors can select these predefined tags but cannot invent arbitrary tags inside the article editor.</p>
      <details className="admin-create-box"><summary>+ Create tag</summary><form action={saveTagAction} className="wiki-fieldset"><div className="form-grid three"><label><span>Name</span><input name="name" required /></label><label><span>Slug</span><input name="slug" placeholder="generated-from-name" /></label><label><span>Sort order</span><input type="number" name="sort_order" defaultValue={0} /></label></div><label><span>Description</span><textarea name="description" rows={2} /></label><label className="check-inline"><input type="checkbox" name="active" defaultChecked /> Active</label><button className="button primary" type="submit">Create tag</button></form></details>
      {!tags.length ? <div className="wiki-message">There are no controlled tags yet.</div> : <table className="management-table"><thead><tr><th>Tag</th><th>Description</th><th>Status</th><th>Order</th><th>Manage</th></tr></thead><tbody>{tags.map((tag) => <tr key={tag.id}><td><strong>{tag.name}</strong><div className="tiny-text">/{tag.slug}</div></td><td>{tag.description || "—"}</td><td>{tag.active ? "Active" : "Inactive"}</td><td>{tag.sort_order}</td><td><details><summary>Edit</summary><form action={saveTagAction} className="inline-edit-form"><input type="hidden" name="id" value={tag.id} /><input name="name" defaultValue={tag.name} required /><input name="slug" defaultValue={tag.slug} required /><input name="description" defaultValue={tag.description || ""} /><input name="sort_order" type="number" defaultValue={tag.sort_order} /><label className="check-inline"><input name="active" type="checkbox" defaultChecked={tag.active} /> Active</label><button className="button" type="submit">Save</button></form><form action={deleteTagAction}><input type="hidden" name="id" value={tag.id} /><button className="button small danger" type="submit">Delete only if unused</button></form></details></td></tr>)}</tbody></table>}
    </section>
  </>;
}
