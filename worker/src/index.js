// Report receiver for Moe's apps (Cloudflare Worker, free plan): Mountpoint, MediaFiles Check, …
// POST /report with a JSON report from an app → JSON file + issue in that app's private GitHub repo
// (`product` → REPOS in wrangler.toml; reports without `product` come from Mountpoint).
// Abuse protection: size limit, strict validation, per-IP and per-day limits. The GitHub token lives only here.

import { DurableObject } from "cloudflare:workers";

const MAX_BYTES = 1_000_000;

// Rate-limit counters. A single instance runs one call at a time and take() is fully synchronous,
// so no two requests can read the same old count (KV could not do this: separate get/put, eventually consistent).
export class Limits extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS counts (key TEXT PRIMARY KEY, n INTEGER NOT NULL, expires INTEGER NOT NULL)");
  }

  // Returns the error text when a limit is reached, otherwise counts the report and returns null.
  take(hourKey, dayKey) {
    const sql = this.ctx.storage.sql;
    const now = Date.now();
    sql.exec("DELETE FROM counts WHERE expires < ?", now);
    const count = (key) => sql.exec("SELECT n FROM counts WHERE key = ?", key).toArray()[0]?.n ?? 0;
    if (count(hourKey) >= Number(this.env.MAX_PER_HOUR_IP)) return "rate limited";
    if (count(dayKey) >= Number(this.env.MAX_PER_DAY)) return "daily limit reached";
    const add = (key, ttlSeconds) => sql.exec(
      "INSERT INTO counts (key, n, expires) VALUES (?, 1, ?) ON CONFLICT(key) DO UPDATE SET n = n + 1", key, now + ttlSeconds * 1000);
    add(hourKey, 3700);
    add(dayKey, 90000);
    return null;
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/report") return json({ error: "not found" }, 404);
    if (request.method !== "POST") return json({ error: "method not allowed" }, 405);
    if (!(request.headers.get("content-type") || "").startsWith("application/json")) return json({ error: "json only" }, 415);
    const length = Number(request.headers.get("content-length") || "0");
    if (length > MAX_BYTES) return json({ error: "too large" }, 413);

    const text = await request.text();
    if (text.length > MAX_BYTES) return json({ error: "too large" }, 413);
    let report;
    try { report = JSON.parse(text); } catch { return json({ error: "invalid json" }, 400); }
    const problem = validate(report);
    if (problem) return json({ error: problem }, 400);
    const repo = JSON.parse(env.REPOS)[report.product || "mountpoint"];
    if (!repo) return json({ error: "unknown product" }, 400);

    // Limits: one Durable Object checks and counts in a single step, so parallel or far-apart requests cannot all pass
    // raw IPs are never stored: the rate-limit key is a salted hash (Fona review M12)
    const ip = await hashIP(request.headers.get("cf-connecting-ip") || "unknown", env.IP_SALT || "");
    const now = new Date();
    // per app: a tester who tries several apps in one hour must not lock himself out of the next one
    const hourKey = `ip:${ip}:${report.product || "mountpoint"}:${now.toISOString().slice(0, 13)}`;
    const dayKey = `day:${now.toISOString().slice(0, 10)}`;
    const limited = await env.LIMITS.get(env.LIMITS.idFromName("limits")).take(hourKey, dayKey);
    if (limited) return json({ error: limited }, 429);

    const id = `${now.toISOString().replace(/[:.]/g, "-")}-${crypto.randomUUID().slice(0, 6)}`;
    const path = `reports/${now.toISOString().slice(0, 10)}/${report.kind}-${id}.json`;
    try {
      await github(env, `/repos/${repo}/contents/${encodeURI(path)}`, "PUT", {
        message: `${report.kind} ${report.app}`,
        content: base64(JSON.stringify(report, null, 2)),
      });
      const issue = await github(env, `/repos/${repo}/issues`, "POST", {
        title: title(report),
        body: body(report, path),
        labels: labels(report),
      });
      return json({ id: String(issue.number) });
    } catch (e) {
      return json({ error: "could not store report" }, 502);
    }
  },
};

function validate(r) {
  if (!r || typeof r !== "object" || Array.isArray(r)) return "not an object";
  if (!["selftest", "problem"].includes(r.kind)) return "unknown kind";
  if (r.product != null && (typeof r.product !== "string" || !/^[a-z-]{1,40}$/.test(r.product))) return "bad product";
  if (typeof r.app !== "string" || !/^[0-9A-Za-z.\-]{1,32}$/.test(r.app)) return "bad app version";
  if (typeof r.build !== "string" || r.build.length > 16) return "bad build";
  if (typeof r.date !== "string" || r.date.length > 40) return "bad date";
  if (!r.system || typeof r.system !== "object" || Object.keys(r.system).length > 40) return "bad system";
  for (const [k, v] of Object.entries(r.system)) if (k.length > 40 || typeof v !== "string" || v.length > 200) return "bad system entry";
  if (!Array.isArray(r.results) || r.results.length > 100) return "bad results";
  for (const c of r.results) {
    if (!c || typeof c.id !== "string" || c.id.length > 40 || !["pass", "fail", "skip"].includes(c.status)) return "bad result";
    if (typeof c.title !== "string" || c.title.length > 100 || typeof c.detail !== "string" || c.detail.length > 1000) return "bad result text";
  }
  if (!Array.isArray(r.log) || r.log.length > 300 || r.log.some((l) => typeof l !== "string" || l.length > 600)) return "bad log";
  if (r.note != null && (typeof r.note !== "string" || r.note.length > 5000)) return "bad note";
  if (r.contact != null && (typeof r.contact !== "string" || r.contact.length > 200)) return "bad contact";
  if (r.kind === "problem" && !(r.note || "").trim()) return "empty problem";
  return null;
}

// Text from a report is untrusted: invisible/bidi/tag characters removed, never rendered as Markdown (Fona review M12).
function clean(s) {
  return String(s).replace(/[\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\u2028\u2029\uFEFF]|[\u{E0000}-\u{E007F}]/gu, "");
}

function codeBlock(s) {
  return "```text\n" + clean(s).replace(/`/g, "ˋ") + "\n```";
}

async function hashIP(ip, salt) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}|${ip}`));
  return [...new Uint8Array(digest)].slice(0, 12).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function title(r) {
  const os = (r.system.macOS || "").replace(/^Version /, "macOS ").replace(/ \(Build.*\)/, "");
  if (r.kind === "problem") return `[problem] ${r.app} · ${os || "no system info"} · ${clean(r.note.trim().split("\n")[0]).slice(0, 60)}`;
  const pass = r.results.filter((c) => c.status === "pass").length;
  const fail = r.results.filter((c) => c.status === "fail").length;
  return `[selftest] ${r.app} · ${os} · ${r.system.arch || ""} · ${pass}/${r.results.length} passed${fail ? ` · ${fail} failed` : ""}`;
}

function labels(r) {
  const l = [r.kind];
  if (r.results.some((c) => c.status === "fail")) l.push("failures");
  return l;
}

function body(r, path) {
  const esc = (s) => clean(s).replace(/\|/g, "\\|").replace(/\n/g, " ").replace(/`/g, "ˋ");
  const lines = [];
  if (r.kind === "problem") {
    lines.push("### Description", "", codeBlock(r.note.trim()), "");
    if (r.contact) lines.push(`**Contact:** ${esc(r.contact)}`, "");
  }
  const sys = Object.entries(r.system).sort(([a], [b]) => a.localeCompare(b));
  if (sys.length) {
    lines.push("### System", "", "| | |", "|---|---|", ...sys.map(([k, v]) => `| ${esc(k)} | ${esc(v)} |`), "");
  }
  if (r.results.length) {
    const icon = { pass: "✅", fail: "❌", skip: "➖" };
    lines.push(`### Results (${r.durationSeconds} s)`, "", "| | Test | Detail | s |", "|---|---|---|---|",
      ...r.results.map((c) => `| ${icon[c.status]} | ${esc(c.id)} | ${esc(c.detail).slice(0, 300)} | ${c.seconds} |`), "");
  }
  lines.push(`Full report: \`${path}\` (app ${esc(r.app)}, build ${esc(r.build)}, ${esc(r.date)})`);
  return lines.join("\n").slice(0, 60000);
}

async function github(env, path, method, payload) {
  const res = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "moe-apps-reports-worker",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`GitHub ${res.status}`);
  return res.json();
}

function base64(s) {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}
