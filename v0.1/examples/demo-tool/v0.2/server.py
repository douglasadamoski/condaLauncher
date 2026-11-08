"""Demo web tool for condaLauncher: standard library only.

Shows how a tool reads the launcher's variables. CL_BANNER is the dev banner
(empty = production look); CL_VERSION and CL_ROLE identify the deployment.
"""
import argparse, html, os, signal, sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

BANNER = os.environ.get("CL_BANNER", "")
VERSION = os.environ.get("CL_VERSION", "?")

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        bar = (f'<div style="background:#b3261e;color:#fff;padding:8px;font:bold 14px sans-serif">'
               f'{html.escape(BANNER)}</div>') if BANNER else ""
        body = f"<!doctype html><title>Demo {VERSION}</title>{bar}<h1>Demo tool {VERSION}</h1><p>OK</p>"
        data = body.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="127.0.0.1")
    a = ap.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    print(f"demo {VERSION} on {a.host}:{a.port} banner={BANNER!r}", flush=True)
    ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()

if __name__ == "__main__":
    main()
