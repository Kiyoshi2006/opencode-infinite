// Cầu nối cục bộ: nhận yêu cầu kiểu OpenAI từ Hermes -> gửi lên OpenCode Zen bằng Bun (kết nối giống OpenCode thật).
// Chạy bằng chính file opencode làm Bun:  BUN_BE_BUN=1 HTTPS_PROXY=http://127.0.0.1:40000 opencode zen_relay.js
const http = require("node:http");
const PORT = Number(process.env.RELAY_PORT || 8787);
const UP = (process.env.UPSTREAM || "https://opencode.ai").replace(/\/$/, "");
const VER = process.env.OC_VER || "2.2.6";
const rnd = (n) => Array.from({ length: n }, () => "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"[Math.floor(Math.random() * 62)]).join("");
const SES = process.env.OC_SESSION || "ses_" + Array.from({ length: 12 }, () => "0123456789abcdef"[Math.floor(Math.random() * 16)]).join("") + rnd(14);
const PROJECT = process.env.OC_PROJECT || "1751ba12936fd079fff18cea3db58f28811c2004";

const server = http.createServer(async (req, res) => {
  try {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    let body = Buffer.concat(chunks);
    if (req.method === "GET" && /\/models$/.test(req.url)) {
      const r = await fetch(UP + "/zen/v1/models", { headers: { "User-Agent": `opencode/latest/${VER}/cli` } });
      res.writeHead(r.status, { "content-type": r.headers.get("content-type") || "application/json" });
      return res.end(Buffer.from(await r.arrayBuffer()));
    }
    if (body.length) {
      try { const j = JSON.parse(body); if (typeof j.model === "string") j.model = j.model.replace(/^opencode(-free)?\//, ""); body = Buffer.from(JSON.stringify(j)); } catch {}
    }
    const path = req.url.replace(/^\/v1/, "/zen/v1");
    const r = await fetch(UP + path, {
      method: req.method,
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer public",
        "User-Agent": `opencode/latest/${VER}/cli`,
        "x-opencode-client": "cli",
        "x-opencode-project": PROJECT,
        "x-opencode-session": SES,
        "x-opencode-session-id": SES,
        "x-session-affinity": SES,
        "x-session-id": SES,
      },
      body: body.length ? body : undefined,
    });
    const h = { "content-type": r.headers.get("content-type") || "application/json" };
    res.writeHead(r.status, h);
    if (!r.body) return res.end();
    for await (const c of r.body) res.write(c);
    res.end();
  } catch (e) {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: "relay: " + e.message } }));
  }
});
server.listen(PORT, "127.0.0.1", () => console.log("zen_relay listening 127.0.0.1:" + PORT));
