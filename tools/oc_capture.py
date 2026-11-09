#!/usr/bin/env python3
"""Proxy ghi lại request mà OpenCode gửi tới Zen, rồi chuyển tiếp lên máy chủ thật (qua HTTPS_PROXY nếu có).
Dùng: python3 oc_capture.py [port] [logfile]"""
import sys, os, json, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
LOG = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/oc-capture.log")
UP = os.environ.get("UPSTREAM", "https://opencode.ai").rstrip("/")
SKIP = {"host", "content-length", "accept-encoding", "connection", "transfer-encoding"}

def log(s):
    with open(LOG, "a") as f:
        f.write(s + "\n")

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def handle_any(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n) if n else b""
        summ = ""
        try:
            j = json.loads(body)
            summ = "keys=%s model=%s stream=%s tools=%s msgs=%s" % (
                sorted(j.keys()), j.get("model"), j.get("stream"),
                len(j.get("tools") or []), len(j.get("messages") or j.get("input") or []))
        except Exception:
            pass
        log("=== %s %s %s %s" % (time.strftime("%H:%M:%S"), self.command, self.path, summ))
        for k, v in self.headers.items():
            log("  %s: %s" % (k, v))
        if body:
            log("  BODY[:1500]: " + body[:1500].decode("utf8", "replace"))
        hdr = {k: v for k, v in self.headers.items() if k.lower() not in SKIP}
        hdr["Accept-Encoding"] = "identity"
        req = urllib.request.Request(UP + self.path, data=body or None, headers=hdr, method=self.command)
        try:
            r = urllib.request.urlopen(req, timeout=300)
            code, data, rh = r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            code, data, rh = e.code, e.read(), e.headers
        except Exception as e:
            code, data, rh = 502, str(e).encode(), {}
        log("  -> upstream %s %s" % (code, data[:200].decode("utf8", "replace").replace("\n", " ")))
        self.send_response(code)
        for k, v in dict(rh).items():
            if k.lower() not in SKIP and k.lower() != "content-encoding":
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    do_GET = do_POST = do_PUT = do_DELETE = handle_any

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
