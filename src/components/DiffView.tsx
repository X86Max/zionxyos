type DiffLine = { kind: "same" | "add" | "remove"; text: string; oldNo?: number; newNo?: number };

function lineDiff(before: string, after: string): DiffLine[] {
  const a = before.split("\n");
  const b = after.split("\n");
  const n = a.length;
  const m = b.length;

  // Keep pathological pasted documents from making the review page expensive.
  if (n * m > 250_000) {
    return [
      ...a.map((text, index) => ({ kind: "remove" as const, text, oldNo: index + 1 })),
      ...b.map((text, index) => ({ kind: "add" as const, text, newNo: index + 1 })),
    ];
  }

  const dp = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  const result: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      result.push({ kind: "same", text: a[i], oldNo: i + 1, newNo: j + 1 });
      i += 1;
      j += 1;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      result.push({ kind: "remove", text: a[i], oldNo: i + 1 });
      i += 1;
    } else {
      result.push({ kind: "add", text: b[j], newNo: j + 1 });
      j += 1;
    }
  }
  while (i < n) result.push({ kind: "remove", text: a[i], oldNo: ++i });
  while (j < m) result.push({ kind: "add", text: b[j], newNo: ++j });
  return result;
}

export function DiffView({ before, after }: { before: string; after: string }) {
  const lines = lineDiff(before, after);
  return (
    <div className="diff-table" role="table" aria-label="Revision comparison">
      {lines.map((line, index) => (
        <div className={`diff-line diff-${line.kind}`} role="row" key={`${index}-${line.kind}`}>
          <span className="diff-no">{line.oldNo ?? ""}</span>
          <span className="diff-no">{line.newNo ?? ""}</span>
          <span className="diff-symbol">{line.kind === "add" ? "+" : line.kind === "remove" ? "−" : " "}</span>
          <code>{line.text || " "}</code>
        </div>
      ))}
    </div>
  );
}
