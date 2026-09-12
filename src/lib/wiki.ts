import { slugify } from "@/lib/utils";

export type WikiCitation = {
  number: number;
  name?: string;
  title?: string;
  url?: string;
  author?: string;
  site?: string;
  date?: string;
  accessed?: string;
  markers: string[];
};

export type TocEntry = {
  level: number;
  text: string;
  id: string;
};

function safeReferenceUrl(raw?: string) {
  if (!raw?.trim()) return undefined;
  try {
    const url = new URL(raw.trim());
    if (url.username || url.password) return undefined;
    return url.protocol === "https:" || url.protocol === "http:" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

function parseFields(raw: string) {
  const fields: Record<string, string> = {};
  for (const part of raw.split("|").map((item) => item.trim()).filter(Boolean)) {
    const index = part.indexOf("=");
    if (index === -1) continue;
    const key = part.slice(0, index).trim().toLowerCase();
    const value = part.slice(index + 1).trim();
    if (key) fields[key] = value;
  }
  return fields;
}

export function prepareWikiMarkdown(content: string) {
  const citations: WikiCitation[] = [];
  const named = new Map<string, WikiCitation>();
  let anonymousCounter = 0;

  let processed = content.replace(/\{\{cite\|([^}]+)\}\}/gi, (_match, raw: string) => {
    const fields = parseFields(raw);
    const name = fields.name?.trim();
    let citation = name ? named.get(name) : undefined;

    if (!citation) {
      citation = {
        number: citations.length + 1,
        name: name || undefined,
        title: fields.title,
        url: safeReferenceUrl(fields.url),
        author: fields.author,
        site: fields.site,
        date: fields.date,
        accessed: fields.accessed,
        markers: [],
      };
      citations.push(citation);
      if (name) named.set(name, citation);
    } else {
      citation.title ||= fields.title;
      citation.url ||= safeReferenceUrl(fields.url);
      citation.author ||= fields.author;
      citation.site ||= fields.site;
      citation.date ||= fields.date;
      citation.accessed ||= fields.accessed;
    }

    anonymousCounter += 1;
    const markerId = `cite-marker-${citation.number}-${anonymousCounter}`;
    citation.markers.push(markerId);
    return `[\\[${citation.number}\\]](#cite-${citation.number} \"${markerId}\")`;
  });

  processed = processed.replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_match, targetRaw: string, labelRaw?: string) => {
    const target = targetRaw.trim();
    const label = (labelRaw || targetRaw).trim();
    return `[${label}](/__wiki/${encodeURIComponent(target)})`;
  });

  return { markdown: processed, citations };
}

export function extractInternalTargets(content: string) {
  const targets = new Set<string>();
  for (const match of content.matchAll(/\[\[([^\]|]+)(?:\|[^\]]+)?\]\]/g)) {
    const target = match[1]?.trim().slice(0, 160);
    if (target) targets.add(target);
    if (targets.size >= 200) break;
  }
  return [...targets];
}

export function extractToc(content: string): TocEntry[] {
  const seen = new Map<string, number>();
  const entries: TocEntry[] = [];

  for (const line of content.split("\n")) {
    const match = line.match(/^(#{2,4})\s+(.+?)\s*#*$/);
    if (!match) continue;
    const level = match[1].length;
    const text = match[2]
      .replace(/\*\*(.*?)\*\*/g, "$1")
      .replace(/\*(.*?)\*/g, "$1")
      .replace(/`(.*?)`/g, "$1")
      .replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_m, target, label) => label || target)
      .trim();
    let id = slugify(text);
    const count = seen.get(id) || 0;
    seen.set(id, count + 1);
    if (count) id = `${id}-${count + 1}`;
    entries.push({ level, text, id });
  }

  return entries;
}

export function headingIds(content: string) {
  return extractToc(content).map((entry) => entry.id);
}
