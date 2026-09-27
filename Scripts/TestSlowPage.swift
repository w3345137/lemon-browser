import AppKit
import WebKit

@main enum TestSlowPage {
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(condition(), label)
    }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        BrowserTab.slowPageDelay = 0.3
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
        from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
        import time
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                body = '<html><body><script>void(0)</script></body></html>'
                if self.path == '/healthy': body = '<html><body><input placeholder="Account"></body></html>'
                if self.path == '/static': body = '<html><body>Hi</body></html>'
                if self.path == '/waiting': body = '<html><head><script src="/slow.js"></script></head><body><input placeholder="Account"></body></html>'
                if self.path == '/slow.js':
                    time.sleep(3)
                    body = 'void(0);'
                data = body.encode()
                self.send_response(200)
                self.send_header('Content-Type','application/javascript' if self.path == '/slow.js' else 'text/html')
                self.send_header('Content-Length',str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            do_POST = do_GET
        server=ThreadingHTTPServer(('127.0.0.1',0), Handler)
        print(server.server_port,flush=True)
        server.serve_forever()
        """]
        let pipe = Pipe(); server.standardOutput = pipe
        try server.run()
        defer { server.terminate() }
        let port = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }
        let tab = BrowserTab(isPrivate: true, startURL: url("blank"))
        defer { tab.tearDown() }
        wait("blank page notice") { tab.slowPageNotice != nil }
        precondition(tab.canRetrySlowPage && tab.navigationError == nil)
        let initial = tab.navigationRevision
        tab.retrySlowPage()
        wait("user retry") { tab.navigationRevision != initial }
        wait("second notice") { tab.slowPageNotice != nil }
        var added = false
        tab.webView?.evaluateJavaScript("document.body.innerHTML='<textarea>unsaved</textarea>'") { _, _ in added = true }
        wait("user input") { added }
        let before = tab.navigationRevision
        tab.retrySlowPage()
        wait("protect input") { !tab.canRetrySlowPage }
        precondition(tab.navigationRevision == before)
        for path in ["healthy", "static"] {
            tab.load(url(path))
            RunLoop.current.run(until: Date().addingTimeInterval(0.9))
            precondition(tab.slowPageNotice == nil, "healthy page must not be classified as blank")
        }
        tab.load(url("waiting"))
        wait("blocked script notice") { tab.slowPageNotice != nil }
        precondition(tab.isLoading)
        wait("late script recovers without reload") { !tab.isLoading && tab.slowPageNotice == nil }
        var post = URLRequest(url: url("post")); post.httpMethod = "POST"; post.httpBody = Data("fixture=1".utf8)
        tab.webView?.load(post)
        wait("post notice") { tab.slowPageNotice != nil }
        precondition(!tab.canRetrySlowPage)
        tab.stopLoading()
        precondition(tab.slowPageNotice == nil)
        let login = URL(string: "https://login.microsoftonline.com/common/authorize?redirect_uri=https%3A%2F%2Fpartner.microsoft.com%2Faad%2FauthPostGateway&state=fixture")!
        precondition(BrowserTab.loginRestartURL(for: login)?.absoluteString == "https://partner.microsoft.com/dashboard")
        precondition(BrowserTab.loginRestartURL(for: URL(string: "https://login.microsoftonline.com.evil.example/?redirect_uri=https://partner.microsoft.com")) == nil)
        precondition(BrowserTab.loginRestartURL(for: URL(string: "https://login.microsoftonline.com/?redirect_uri=https://partner.microsoft.com.evil.example")) == nil)
        print("slow-page-tests=passed")
    }
}
