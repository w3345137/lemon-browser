#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/set":
            self.send_response(200)
            self.send_header(
                "Set-Cookie",
                "lemon_session_fixture_v2=present; Path=/; HttpOnly; SameSite=Lax",
            )
            body = "<title>Cookie Set</title><h1>cookie-set</h1>"
        elif self.path == "/clear":
            self.send_response(200)
            self.send_header(
                "Set-Cookie",
                "lemon_session_fixture_v2=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax",
            )
            body = "<title>Cookie Cleared</title><h1>cookie-cleared</h1>"
        elif self.path == "/check":
            self.send_response(200)
            present = "lemon_session_fixture_v2=present" in self.headers.get("Cookie", "")
            status = "cookie-present" if present else "cookie-missing"
            body = f"<title>{status}</title><h1>{status}</h1>"
        else:
            self.send_response(404)
            body = "<title>Not Found</title>"

        encoded = body.encode("utf-8")
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18767), Handler).serve_forever()
