export function Flash({ error, success }: { error?: string; success?: string }) {
  if (!error && !success) return null;
  return <div className={`flash ${error ? "error" : "success"}`}>{error || success}</div>;
}
