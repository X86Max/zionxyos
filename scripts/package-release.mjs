import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const root = process.cwd();
const projectName = path.basename(root);
const parent = path.dirname(root);
const requested = process.argv[2] || `${projectName}-rc.zip`;
const output = path.isAbsolute(requested) ? requested : path.join(parent, requested);
const checksumFile = `${output}.sha256`;

if (projectName !== "zionxyos-v0.3") throw new Error(`Run this script from zionxyos-v0.3, not ${projectName}.`);

// Do not produce an archive from a tree that already fails static release checks.
execFileSync(process.execPath, [path.join(root, "scripts/validate-release.mjs")], { cwd: root, stdio: "inherit" });

const localOnlyArtifacts = [".env", ".env.local", ".env.production", "tsconfig.tsbuildinfo"];
const presentLocalOnlyArtifacts = localOnlyArtifacts.filter((name) => fs.existsSync(path.join(root, name)));
if (presentLocalOnlyArtifacts.length) {
  console.log(`Excluding local/private artifacts from archive: ${presentLocalOnlyArtifacts.join(", ")}`);
}

for (const target of [output, checksumFile]) if (fs.existsSync(target)) fs.unlinkSync(target);

const excludes = [
  `${projectName}/node_modules/*`,
  `${projectName}/.next/*`,
  `${projectName}/.git/*`,
  `${projectName}/.env`,
  `${projectName}/.env.local`,
  `${projectName}/.env.production`,
  `${projectName}/.env.*.local`,
  `${projectName}/*.tsbuildinfo`,
  `${projectName}/**/*.tsbuildinfo`,
  `${projectName}/*.log`,
  `${projectName}/**/*.log`,
  `${projectName}/.DS_Store`,
  `${projectName}/**/.DS_Store`,
];

execFileSync("zip", ["-r", "-X", "-q", output, projectName, "-x", ...excludes], { cwd: parent, stdio: "inherit" });
execFileSync("unzip", ["-tqq", output], { stdio: "inherit" });

const bytes = fs.readFileSync(output);
const hash = crypto.createHash("sha256").update(bytes).digest("hex");
fs.writeFileSync(checksumFile, `${hash}  ${path.basename(output)}\n`);

const listing = execFileSync("unzip", ["-Z1", output], { encoding: "utf8" }).trim().split(/\r?\n/).filter(Boolean);
const forbiddenArchiveEntries = listing.filter((entry) => /(^|\/)(node_modules|\.next|\.git)(\/|$)|(^|\/)\.env(?:$|\.(?!example))|\.tsbuildinfo$|\.log$|(^|\/)\.DS_Store$/i.test(entry));
if (forbiddenArchiveEntries.length) {
  fs.unlinkSync(output);
  fs.unlinkSync(checksumFile);
  throw new Error(`Archive contains forbidden entries: ${forbiddenArchiveEntries.slice(0, 20).join(", ")}`);
}

console.log(`\nArchive OK: ${output}`);
console.log(`Entries: ${listing.length}`);
console.log(`SHA-256: ${hash}`);
console.log(`Checksum: ${checksumFile}`);
