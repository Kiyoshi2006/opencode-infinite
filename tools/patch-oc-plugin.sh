#!/usr/bin/env bash
# Ép plugin oc-free-provider của Hermes đi qua proxy WARP (nó đang bỏ qua HTTPS_PROXY).
# Dùng: bash patch-oc-plugin.sh          (vá)
#       bash patch-oc-plugin.sh --undo   (trả lại bản gốc)
set -u
F="$(find "$HOME/.hermes" -name hermes_oc_client.py 2>/dev/null | head -1)"
[ -z "$F" ] && { echo "Không tìm thấy hermes_oc_client.py trong ~/.hermes"; exit 1; }
echo "File plugin: $F"
if [ "${1:-}" = "--undo" ]; then
  [ -f "$F.orig" ] && cp -f "$F.orig" "$F" && echo "Đã trả lại bản gốc." || echo "Không có bản sao lưu."; exit 0
fi
if grep -q "OC_PROXY_PATCH" "$F"; then echo "Đã vá rồi."; exit 0; fi
[ -f "$F.orig" ] || cp -f "$F" "$F.orig"
python3 - "$F" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf8").read()
pat = re.compile(r'^(\s*)_OPENER\s*=\s*urllib\.request\.build_opener\(\s*_NoRedirect\s*\)\s*$', re.M)
if not pat.search(s):
    print("Không thấy dòng '_OPENER = urllib.request.build_opener(_NoRedirect)' — plugin đã đổi, báo lại cho Claude."); sys.exit(2)
new = (r'\1# OC_PROXY_PATCH: ép đi qua proxy WARP (đặt OC_PROXY=off để tắt)' '\n'
       r'\1_OC_PX = __import__("os").environ.get("OC_PROXY", "http://127.0.0.1:40000")' '\n'
       r'\1_OPENER = urllib.request.build_opener(*([urllib.request.ProxyHandler({"http": _OC_PX, "https": _OC_PX})] if _OC_PX != "off" else []), _NoRedirect)')
open(p, "w", encoding="utf8").write(pat.sub(new, s, count=1))
PY
rc=$?; [ $rc -ne 0 ] && exit $rc
python3 -m py_compile "$F" && echo "Đã vá xong (kiểm tra cú pháp OK). Bản gốc: $F.orig"
