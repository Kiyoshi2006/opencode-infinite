#!/usr/bin/env bash
# OpenCode thật -> cầu nối BUN (chuyển tiếp nguyên xi header/body) -> Zen. Mọi lệnh đều có timeout.
P="${PROXY:-http://127.0.0.1:40000}"
OC="$(command -v opencode || ls $HOME/.opencode/bin/opencode 2>/dev/null)"
D="$(cd "$(dirname "$0")" && pwd)"
LOGF="$HOME/relay.log"; : > "$LOGF"
echo "== 0. đối chứng: OpenCode gọi thẳng (không qua cầu nối)"
timeout 90 env HTTPS_PROXY=$P "$OC" run --standalone -m opencode/big-pickle "Reply with exactly: OK" </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^\s*$' | tail -1
echo "== 1. OpenCode -> cầu nối Bun (nguyên xi) -> Zen"
( HTTPS_PROXY=$P HTTP_PROXY=$P RELAY_PASSTHROUGH=1 RELAY_LOG="$LOGF" BUN_BE_BUN=1 timeout 100 "$OC" "$D/zen_relay.js" </dev/null >/dev/null 2>&1 ) &
sleep 4
( cd $HOME && OPENCODE_CONFIG_CONTENT='{"provider":{"opencode":{"options":{"baseURL":"http://127.0.0.1:8787/zen/v1"}}}}' HTTPS_PROXY=$P HTTP_PROXY=$P NO_PROXY=localhost,127.0.0.1,::1 timeout 80 "$OC" run --standalone -m opencode/big-pickle "Reply with exactly: OK" </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^\s*$' | tail -2 | cut -c1-160 )
echo "-- trạng thái cầu nối nhận được từ Zen:"; grep -E "^===|upstream" "$LOGF" | cut -c1-110
wait 2>/dev/null
echo "(chi tiết đầy đủ trong $LOGF)"
