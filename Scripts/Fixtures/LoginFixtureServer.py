#!/usr/bin/env python3
"""Lemon QA 夹具：主站 18771（直接登录表单 + iframe 父页），子站 18772（跨源 iframe 登录框）。
localhost 不同端口 = 跨源但同可注册域，用于验证 postMessage 扇出填充。"""

import http.server
import socketserver
import threading

PARENT_PORT = 18771
FRAME_PORT = 18772

LOGIN_FORM = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>QA 登录页</title></head>
<body>
<h1>QALoginFixture</h1>
<form action="/success" method="get">
  <input type="text" name="username" autocomplete="username" placeholder="账号">
  <input type="password" name="password" autocomplete="current-password" placeholder="密码">
  <button type="submit">登录</button>
</form>
</body></html>"""

IFRAME_PARENT = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>QA iframe 父页</title></head>
<body>
<h1>QAIframeParent</h1>
<iframe src="http://localhost:%d/frame-login.html" width="420" height="220"></iframe>
</body></html>""" % FRAME_PORT

FRAME_LOGIN = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>QA iframe 登录框</title></head>
<body>
<h2>QAIframeLogin</h2>
<input type="text" id="frame-user" autocomplete="username" placeholder="iframe 账号">
<input type="password" id="frame-pass" autocomplete="current-password" placeholder="iframe 密码">
</body></html>"""

SUCCESS = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>QA 登录成功</title></head>
<body><h1>QALoginSuccess</h1></body></html>"""


class ParentHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/success"):
            self._respond(SUCCESS)
        elif self.path.startswith("/iframe-parent"):
            self._respond(IFRAME_PARENT)
        else:
            self._respond(LOGIN_FORM)

    def _respond(self, body):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


class FrameHandler(ParentHandler):
    def do_GET(self):
        self._respond(FRAME_LOGIN)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    parent = Server(("127.0.0.1", PARENT_PORT), ParentHandler)
    frame = Server(("127.0.0.1", FRAME_PORT), FrameHandler)
    threading.Thread(target=frame.serve_forever, daemon=True).start()
    print(f"qa-login-fixture listening: {PARENT_PORT} (parent) / {FRAME_PORT} (frame)", flush=True)
    parent.serve_forever()
