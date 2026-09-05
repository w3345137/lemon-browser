#!/usr/bin/env python3

import http.server
import socketserver
import time
import sys


PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18767
CHUNK = b"L" * (64 * 1024)
CHUNK_COUNT = 256
FILENAME = "Lemon-download-integrity-fixture.bin"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/download":
            self.send_error(404)
            return

        total = len(CHUNK) * CHUNK_COUNT
        offset = 0
        if self.headers.get("Range", "").startswith("bytes="):
            offset = int(self.headers["Range"][6:].split("-")[0])
        self.send_response(206 if offset else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{FILENAME}"')
        self.send_header("Content-Length", str(total - offset))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"lemon-fixture-1"')
        self.send_header("Last-Modified", "Mon, 01 Jun 2026 00:00:00 GMT")
        if offset:
            self.send_header("Content-Range", f"bytes {offset}-{total - 1}/{total}")
        self.end_headers()

        try:
            for position in range(offset, total, len(CHUNK)):
                self.wfile.write(CHUNK[:min(len(CHUNK), total - position)])
                self.wfile.flush()
                time.sleep(0.03)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        print(format % args, flush=True)


class Server(socketserver.TCPServer):
    allow_reuse_address = True


with Server(("127.0.0.1", PORT), Handler) as server:
    print(f"download-fixture-server=http://127.0.0.1:{PORT}/download", flush=True)
    server.serve_forever()
