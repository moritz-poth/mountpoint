// Mountpoint report receiver (Cloudflare Worker, free plan).
// POST /report with a JSON report from the app → JSON file + issue in a private GitHub repo.
// Abuse protection: size limit, strict validation, per-IP and per-day limits. The GitHub token lives only here.

const MAX_BYTES = 1_000_000;

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

    // Limits (KV is eventually consistent – good enough to stop floods, nothing is billed on the free plan)
    const ip = request.headers.get("cf-connecting-ip") || "unknown";
    const now = new Date();
    const hourKey = `ip:${ip}:${now.toISOString().slice(0, 13)}`;
    const dayKey = `day:${now.toISOString().slice(0, 10)}`;
    const [perIp, perDay] = await Promise.all([env.LIMITS.get(hourKey), env.LIMITS.get(dayKey)]);
    if (Number(perIp || 0) >= Number(env.MAX_PER_HOUR_IP)) return json({ error: "rate limited" }, 429);
    if (Number(perDay || 0) >= Number(env.MAX_PER_DAY)) return json({ error: "daily limit reached" }, 429);
    await Promise.all([
      env.LIMITS.put(hourKey, String(Number(perIp || 0) + 1), { expirationTtl: 3700 }),
      env.LIMITS.put(dayKey, String(Number(perDay || 0) + 1), { expirationTtl: 90000 }),
    ]);

    const id = `${now.toISOString().replace(/[:.]/g, "-")}-${crypto.randomUUID().slice(0, 6)}`;
    const path = `reports/${now.toISOString().slice(0, 10)}/${report.kind}-${id}.json`;
    try {
      await github(env, `/repos/${env.REPO}/contents/${encodeURI(path)}`, "PUT", {
        message: `${report.kind} ${report.app}`,
        content: base64(JSON.stringify(report, null, 2)),
      });
      const issue = await github(env, `/repos/${env.REPO}/issues`, "POST", {
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

function title(r) {
  const os = (r.system.macOS || "").replace(/^Version /, "macOS ").replace(/ \(Build.*\)/, "");
  if (r.kind === "problem") return `[problem] ${r.app} · ${os || "no system info"} · ${r.note.trim().split("\n")[0].slice(0, 60)}`;
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
  const esc = (s) => String(s).replace(/\|/g, "\\|").replace(/\n/g, " ");
  const lines = [];
  if (r.kind === "problem") {
    lines.push("### Description", "", r.note.trim(), "");
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
      "User-Agent": "mountpoint-reports-worker",
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
