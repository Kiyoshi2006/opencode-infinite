#!/usr/bin/env bash
# Thử: dùng chính file opencode làm Bun để gọi Zen. Mọi lệnh đều có timeout, không treo.
P="${PROXY:-http://127.0.0.1:40000}"
OC="$(command -v opencode || ls $HOME/.opencode/bin/opencode 2>/dev/null)"
D="$(cd "$(dirname "$0")" && pwd)"
echo "opencode: $OC"
echo "== 1. opencode có chạy được như Bun không"
BUN_BE_BUN=1 timeout 15 "$OC" --version </dev/null 2>&1 | head -3
cat > /tmp/zen_t.js <<'JS'
const H={"Content-Type":"application/json",Authorization:"Bearer public","User-Agent":"opencode/latest/2.2.6/cli","x-opencode-client":"cli"};
fetch("https://opencode.ai/zen/v1/chat/completions",{method:"POST",headers:H,body:JSON.stringify({model:"big-pickle",messages:[{role:"user",content:"Reply with: OK"}],max_tokens:8})})
 .then(async r=>console.log("BUN fetch → HTTP",r.status,(await r.text()).slice(0,160))).catch(e=>console.log("BUN lỗi:",e.message));
JS
echo "== 2. Bun fetch trực tiếp lên Zen (qua proxy WARP)"
HTTPS_PROXY=$P HTTP_PROXY=$P BUN_BE_BUN=1 timeout 30 "$OC" /tmp/zen_t.js </dev/null 2>&1 | head -5
echo "== 3. Cầu nối: khởi động 25s rồi thử một yêu cầu kiểu OpenAI qua cầu nối"
( HTTPS_PROXY=$P HTTP_PROXY=$P BUN_BE_BUN=1 timeout 25 "$OC" "$D/zen_relay.js" </dev/null >/tmp/zen_relay.log 2>&1 ) &
sleep 4
curl -s -m 20 http://127.0.0.1:8787/v1/chat/completions -H "Content-Type: application/json" -d '{"model":"deepseek-v4.1-flash-free","messages":[{"role":"user","content":"Reply with: OK"}],"max_tokens":8}' | head -c 300; echo
wait
echo "(log cầu nối:)"; head -3 /tmp/zen_relay.log
