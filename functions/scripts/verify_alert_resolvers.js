/* eslint-disable */
/**
 * Every admin alert type must have a way to close: a done-test in
 * alert_resolution.ts RESOLVERS, or an entry in CLOSED_ELSEWHERE naming where
 * it is closed (or that it is manual by design). An alert with neither sits in
 * the queue for good - issue_fix_disputed, issue_pending_stale and the deposit
 * dispute all shipped that way.
 *
 *   npm run build && node scripts/verify_alert_resolvers.js
 *
 * No emulator needed: it reads the compiled module and scans src for every
 * type passed to writeAdminAlert / writeAdminAlertOnce / upsertAdminAlert.
 */

const fs = require("fs");
const path = require("path");
const {RESOLVED_TYPES, CLOSED_ELSEWHERE} =
  require("../lib/alert_resolution.js");

const src = path.join(__dirname, "..", "src");
const raised = new Map(); // type -> files
const unreadable = [];

for (const f of fs.readdirSync(src).filter((n) => n.endsWith(".ts"))) {
  const s = fs.readFileSync(path.join(src, f), "utf8");
  const consts = Object.fromEntries(
    [...s.matchAll(/const ([A-Z_]+) = "([a-z_]+)";/g)].map((m) => [m[1], m[2]]),
  );
  for (const m of s.matchAll(/\b(writeAdminAlert|writeAdminAlertOnce|upsertAdminAlert)\(/g)) {
    if (/function\s*$/.test(s.slice(Math.max(0, m.index - 30), m.index))) continue;
    const chunk = s.slice(m.index + m[0].length, m.index + m[0].length + 400);
    const t = chunk.match(/type:\s*([^,]+?),\s*\n\s*severity/s);
    const line = s.slice(0, m.index).split("\n").length;
    if (!t) { unreadable.push(`${f}:${line}`); continue; }
    const lits = [...t[1].matchAll(/"([a-z_]+)"/g)].map((x) => x[1]);
    const types = lits.length ? lits : [consts[t[1].trim()]];
    for (const ty of types) {
      if (!ty) { unreadable.push(`${f}:${line}`); continue; }
      raised.set(ty, [...(raised.get(ty) ?? []), f]);
    }
  }
}

let failures = 0;
for (const [type, files] of [...raised].sort()) {
  const ok = RESOLVED_TYPES.includes(type) || type in CLOSED_ELSEWHERE;
  console.log(`${ok ? "PASS" : "FAIL"}  ${type}  (${[...new Set(files)].join(", ")})`);
  if (!ok) failures++;
}
for (const u of unreadable) {
  console.log(`FAIL  could not read the alert type at ${u}`);
  failures++;
}
// A registry entry for a type nothing raises any more is stale, not harmful.
for (const t of [...RESOLVED_TYPES, ...Object.keys(CLOSED_ELSEWHERE)]) {
  if (!raised.has(t)) console.log(`note  ${t} is registered but never raised`);
}

console.log(failures ? `\n${failures} FAILED` : "\nALL PASS");
process.exit(failures ? 1 : 0);
