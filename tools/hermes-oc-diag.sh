#!/usr/bin/env bash
# Chẩn đoán: vì sao Hermes (oc-free-provider) bị FreeUsageLimit mà OpenCode thật vẫn chạy trên cùng IP.
# Chạy: bash hermes-oc-diag.sh   → in báo cáo + lưu ~/hermes-oc-diag.txt (dán file đó lên cho Claude)
P="${PROXY:-http://127.0.0.1:40000}"
OUT="$HOME/hermes-oc-diag.txt"; : > "$OUT"
EP=https://opencode.ai/zen/v1/chat/completions
M="${MODEL:-deepseek-v4.1-flash-free}"
say() { echo "$*" | tee -a "$OUT"; }
cls() { local r="$1"; if echo "$r" | grep -q FreeUsageLimit; then echo LIMIT; elif echo "$r" | grep -q '"choices"\|data: {'; then echo OK; else echo "KHAC: $(echo "$r" | tr '\n' ' ' | head -c 120)"; fi; }
S="ses_$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
BODY="{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with: OK\"}],\"max_tokens\":8}"
BODYS="{\"model\":\"$M\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with: OK\"}],\"max_tokens\":8}"

say "### $(date '+%F %T')  model=$M"
say "== 0. proxy / IP"
nc -z 127.0.0.1 40000 && say "proxy 40000: LISTEN" || say "proxy 40000: KHÔNG listen"
say "IP qua proxy: $(curl -s -m 10 -x $P https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp)=' | tr '\n' ' ')"

say "== 1. OpenCode THẬT (opencode run --standalone, qua proxy)"
OC="$(command -v opencode || ls $HOME/.opencode/bin/opencode 2>/dev/null)"
if [ -n "$OC" ]; then
  r="$(cd $HOME && HTTPS_PROXY=$P HTTP_PROXY=$P NO_PROXY=localhost,127.0.0.1,::1 timeout 120 "$OC" run --standalone "Reply with exactly: OK" 2>&1 | tail -5)"
  say "opencode run → $(echo "$r" | tr '\n' ' ' | head -c 300)"
else say "không tìm thấy opencode"; fi

say "== 2. curl giả lập (cùng IP, cùng lúc)"
H0=(-H "Authorization: Bearer public" -H "Content-Type: application/json")
HO=(-H "User-Agent: opencode/latest/2.2.6/cli" -H "x-opencode-client: cli" -H "x-opencode-project: global" -H "x-opencode-session: $S" -H "x-opencode-session-id: $S" -H "X-Session-Id: $S" -H "x-session-affinity: $S")
r=$(curl -s -m 25 -x $P $EP "${H0[@]}" -H "User-Agent: opencode/1.18.31" -H "x-opencode-session: $S" -d "$BODY");  say "A  như plugin Hermes (non-stream)      : $(cls "$r")"
r=$(curl -s -m 25 -x $P $EP "${H0[@]}" -H "Accept: text/event-stream" -H "User-Agent: opencode/1.18.31" -H "x-opencode-session: $S" -d "$BODYS"); say "A2 như plugin Hermes (stream)          : $(cls "$r")"
r=$(curl -s -m 25 -x $P $EP "${H0[@]}" "${HO[@]}" -d "$BODY");  say "B  header OpenCode (non-stream)        : $(cls "$r")"
r=$(curl -s -m 25 -x $P $EP "${H0[@]}" "${HO[@]}" -H "Accept: text/event-stream" -d "$BODYS"); say "B2 header OpenCode (stream)            : $(cls "$r")"
r=$(curl -s -m 25 --http2 -x $P $EP "${H0[@]}" "${HO[@]}" -d "$BODY"); say "C  header OpenCode + HTTP/2            : $(cls "$r")"
r=$(curl -s -m 25 -x $P $EP "${H0[@]}" "${HO[@]}" -d "{\"model\":\"$M\",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[{\"role\":\"system\",\"content\":\"You are opencode, an interactive CLI tool.\"},{\"role\":\"user\",\"content\":\"Reply with: OK\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"noop\",\"description\":\"x\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}]}"); say "D  body kiểu OpenCode (system+tools+usage): $(cls "$r")"

say "== 3. urllib (Python) y hệt plugin"
python3 - <<PY 2>&1 | tee -a "$OUT"
import urllib.request, json, os
os.environ["HTTPS_PROXY"]="$P"; os.environ["HTTP_PROXY"]="$P"
req=urllib.request.Request("$EP", data=json.dumps({"model":"$M","stream":True,"messages":[{"role":"user","content":"Reply with: OK"}],"max_tokens":8}).encode(),
  headers={"Authorization":"Bearer public","Content-Type":"application/json","Accept":"text/event-stream","User-Agent":"opencode/1.18.31","x-opencode-session":"$S"})
try:
    r=urllib.request.urlopen(req,timeout=25); print("urllib plugin-style → HTTP",r.status, r.read(200))
except Exception as e:
    b=getattr(e,"read",lambda:b"")(); print("urllib plugin-style →", e, b[:160])
PY

say "== 4. GHI LẠI request thật của OpenCode (proxy trung gian cổng 8899)"
rm -f "$HOME/oc-capture.log"
python3 "$(dirname "$0")/oc_capture.py" 8899 "$HOME/oc-capture.log" >/dev/null 2>&1 &
CP=$!; sleep 1
if [ -n "$OC" ]; then
  ( cd $HOME && OPENCODE_CONFIG_CONTENT='{"provider":{"opencode":{"options":{"baseURL":"http://127.0.0.1:8899/zen/v1"}}}}' HTTPS_PROXY=$P HTTP_PROXY=$P NO_PROXY=localhost,127.0.0.1,::1 timeout 120 "$OC" run --standalone "Reply with exactly: OK" >/dev/null 2>&1 )
fi
kill $CP 2>/dev/null
if [ -s "$HOME/oc-capture.log" ]; then
  say "ĐÃ BẮT ĐƯỢC request thật (chi tiết: ~/oc-capture.log). Header + tóm tắt body:"
  grep -E "^===|^  [A-Za-z-]+:|upstream" "$HOME/oc-capture.log" | grep -viE "authorization" | head -60 | tee -a "$OUT"
else
  say "KHÔNG bắt được request nào (OpenCode không đi qua baseURL ghi đè) — báo lại cho Claude."
fi
say "== xong. Gửi file $OUT (và ~/oc-capture.log nếu có)"
