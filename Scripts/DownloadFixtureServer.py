#!/usr/bin/env python3

import http.server
import socketserver
import time


PORT = 18767
CHUNK = b"L" * (64 * 1024)
CHUNK_COUNT = 256
FILENAME = "Lemon-download-integrity-fixture.bin"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/download":
            self.send_error(404)
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{FILENAME}"')
        self.send_header("Content-Length", str(len(CHUNK) * CHUNK_COUNT))
        self.end_headers()

        try:
            for _ in range(CHUNK_COUNT):
                self.wfile.write(CHUNK)
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
