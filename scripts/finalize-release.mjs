import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { execFileSync } from "node:child_process";

const root = process.cwd();
const projectName = path.basename(root);
if (projectName !== "zionxyos-v0.3") throw new Error(`Run this script from zionxyos-v0.3, not ${projectName}.`);

const nodeMajor = Number(process.versions.node.split(".")[0]);
if (nodeMajor !== 24) throw new Error(`Zionxyos v0.3 finalization requires Node.js 24.x; current runtime is ${process.versions.node}. Run 'nvm use 24' first.`);

const packageJson = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
if (packageJson.engines?.node !== "24.x") throw new Error("package.json must pin engines.node to 24.x before finalization.");
if (!/^npm@11\./.test(packageJson.packageManager || "")) throw new Error("package.json must pin the npm 11 package manager before finalization.");

const lockfile = path.join(root, "package-lock.json");
if (!fs.existsSync(lockfile)) {
  throw new Error("package-lock.json is missing. Run 'npm install' once with Node 24/npm 11, review the generated lockfile, then run 'npm run release:final'.");
}

function npm(args) {
  execFileSync(process.platform === "win32" ? "npm.cmd" : "npm", args, { cwd: root, stdio: "inherit" });
}

console.log("Zionxyos v0.3 final-release gate");
console.log(`Runtime: Node ${process.versions.node}`);
console.log("1/4 Verifying a reproducible clean dependency install with package-lock.json…");
npm(["ci", "--no-audit", "--no-fund"]);

console.log("2/4 Verifying the installed top-level dependency tree…");
npm(["ls", "--depth=0"]);

console.log("3/4 Running dependency-complete preflight (validator + typecheck + lint + Next production build)…");
npm(["run", "preflight"]);

console.log("4/4 Packaging the production-approved final archive…");
const outputName = "zionxyos-v0.3-final.zip";
execFileSync(process.execPath, [path.join(root, "scripts/package-release.mjs"), outputName], { cwd: root, stdio: "inherit" });

const output = path.join(path.dirname(root), outputName);
const checksum = `${output}.sha256`;
if (!fs.existsSync(output) || !fs.existsSync(checksum)) throw new Error("Final archive or checksum is missing after packaging.");
console.log("\nFINAL RELEASE GATE PASSED.");
console.log(`Archive: ${output}`);
console.log(`Checksum: ${checksum}`);
console.log("Migration 003 may only be treated as production-ready after this message appears and the release checklist is completed.");
