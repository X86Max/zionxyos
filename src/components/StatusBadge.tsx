import type { ArticleStatus, RevisionStatus } from "@/lib/types";

const labels: Record<ArticleStatus | RevisionStatus, string> = {
  draft: "Draft",
  pending_review: "Pending review",
  published: "Published",
  changes_requested: "Changes requested",
  approved: "Approved",
  rejected: "Rejected",
};

export function StatusBadge({ status }: { status: ArticleStatus | RevisionStatus }) {
  return <span className={`status status-${status}`}>{labels[status]}</span>;
}
