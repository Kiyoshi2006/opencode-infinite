// Phát lại yêu cầu THẬT của OpenCode (từ relay.log) bằng Bun, mỗi lần đổi 1 thành phần, in mã trạng thái.
// Chạy: HTTPS_PROXY=http://127.0.0.1:40000 BUN_BE_BUN=1 opencode bisect.js ~/relay.log
const fs = require("node:fs");
const { execFileSync } = require("node:child_process");
const file = process.argv[2] || process.env.HOME + "/relay.log";
const UP = (process.env.UPSTREAM || "https://opencode.ai") + "/zen/v1/chat/completions";
const blocks = fs.readFileSync(file, "utf8").split(/^=== /m).slice(1);
let pick = null;
for (const b of blocks) {
  const h = b.match(/^  HEADERS (.*)$/m), d = b.match(/^  BODY (.*)$/m);
  if (!h || !d) continue;
  const o = { headers: JSON.parse(h[1]), body: d[1] };
  if (o.body.includes('"tools"') || !pick) pick = o;
}
if (!pick) { console.log("không đọc được yêu cầu từ", file); process.exit(1); }
const DROP = ["host", "content-length", "connection", "accept-encoding", "transfer-encoding"];
const base = () => Object.fromEntries(Object.entries(pick.headers).filter(([k]) => !DROP.includes(k)));
const bodyObj = () => JSON.parse(pick.body);
const without = (pred) => (h) => Object.fromEntries(Object.entries(h).filter(([k]) => !pred(k)));
const V = [
  ["V0  nguyên xi (Bun)", (h, b) => [h, b]],
  ["V1  bỏ traceparent + b3", (h, b) => [without((k) => k === "traceparent" || k === "b3")(h), b]],
  ["V2  bỏ mọi header x-opencode-*/x-session*", (h, b) => [without((k) => /^x-(opencode|session)/.test(k))(h), b]],
  ["V3  đổi User-Agent thành opencode/1.18.31", (h, b) => [{ ...h, "user-agent": "opencode/1.18.31" }, b]],
  ["V4  chỉ giữ authorization+content-type+user-agent", (h, b) => [Object.fromEntries(Object.entries(h).filter(([k]) => ["authorization", "content-type", "user-agent"].includes(k))), b]],
  ["V5  body nhỏ (hi, 1 token, không stream)", (h) => [h, JSON.stringify({ model: bodyObj().model, messages: [{ role: "user", content: "hi" }], max_tokens: 1 })]],
  ["V6  body thật nhưng bỏ tools", (h, b) => { const o = bodyObj(); delete o.tools; delete o.tool_choice; return [h, JSON.stringify(o)]; }],
  ["V7  body thật nhưng system prompt thay bằng 'hi'", (h, b) => { const o = bodyObj(); o.messages = o.messages.map((m) => (m.role === "system" ? { ...m, content: "hi" } : m)); return [h, JSON.stringify(o)]; }],
  ["V8  body thật, bỏ stream_options", (h, b) => { const o = bodyObj(); delete o.stream_options; return [h, JSON.stringify(o)]; }],
  ["V9  header đảo thứ tự", (h, b) => [Object.fromEntries(Object.entries(h).reverse()), b]],
];
(async () => {
  console.log("yêu cầu mẫu: model=" + bodyObj().model + " body=" + pick.body.length + " byte, header=" + Object.keys(base()).length);
  for (const [name, fn] of V) {
    const [h, b] = fn(base(), pick.body);
    const body = typeof b === "string" ? b : JSON.stringify(b);
    try {
      const ac = new AbortController(); const t = setTimeout(() => ac.abort(), 30000);
      const r = await fetch(UP, { method: "POST", headers: h, body, signal: ac.signal });
      let txt = ""; try { txt = (await r.text()).slice(0, 80); } catch {}
      clearTimeout(t);
      console.log(name.padEnd(54), r.status, r.status === 429 ? "LIMIT" : r.ok ? "OK" : txt.replace(/\s+/g, " "));
    } catch (e) { console.log(name.padEnd(54), "LỖI", e.message); }
  }
  // curl phát lại nguyên xi (thứ tự + chữ hoa/thường giữ nguyên) để xem dấu vân tay kết nối có quan trọng không
  try {
    const args = ["-s", "-m", "30", "-o", "/dev/null", "-w", "%{http_code}", UP];
    for (const [k, v] of Object.entries(base())) args.push("-H", k + ": " + v);
    args.push("--data-binary", pick.body);
    const proxy = process.env.HTTPS_PROXY; if (proxy) args.unshift("-x", proxy);
    const code = execFileSync("curl", args, { encoding: "utf8" });
    console.log("C0  curl phát lại nguyên xi".padEnd(54), code, code === "429" ? "LIMIT" : code === "200" ? "OK" : "");
  } catch (e) { console.log("C0  curl lỗi", e.message); }
})();
