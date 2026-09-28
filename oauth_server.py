#!/usr/bin/env python3
import sys
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler

OK_PAGE = b"""<!doctype html>
<html><head><meta charset="utf-8"><title>Mastodon login</title></head>
<body style="font-family: system-ui, sans-serif; padding: 3rem; text-align: center">
<h1>Login successful</h1><p>You can close this tab and return to Omarchy.</p>
</body></html>"""

ERR_PAGE = b"""<!doctype html>
<html><head><meta charset="utf-8"><title>Mastodon login failed</title></head>
<body style="font-family: system-ui, sans-serif; padding: 3rem; text-align: center">
<h1>Login failed</h1><p>Return to Omarchy and try again.</p>
</body></html>"""


def fail(message, status):
    sys.stderr.write(message + "\n")
    sys.stderr.flush()
    try:
        sys.stdout.write("OAUTH_ERROR:" + message + "\n")
        sys.stdout.flush()
    except Exception:
        pass
    sys.exit(status)


class CallbackHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        error = params.get("error", [""])[0]
        code = params.get("code", [""])[0]

        if error:
            self.send_response(400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(ERR_PAGE)))
            self.end_headers()
            self.wfile.write(ERR_PAGE)
            fail("access_denied", 1)

        if not code:
            self.send_response(400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(ERR_PAGE)))
            self.end_headers()
            self.wfile.write(ERR_PAGE)
            fail("missing_code", 1)

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(OK_PAGE)))
        self.end_headers()
        self.wfile.write(OK_PAGE)

        sys.stdout.write(code)
        sys.stdout.flush()
        sys.exit(0)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    if len(sys.argv) < 2:
        fail("missing_port_argument", 2)
    try:
        port = int(sys.argv[1])
    except ValueError:
        fail("invalid_port", 2)

    try:
        server = HTTPServer(("127.0.0.1", port), CallbackHandler)
    except OSError as error:
        fail("port_unavailable:%d" % port, 3)

    server.handle_request()
