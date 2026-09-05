import AppKit
import WebKit

@main
enum TestNavigationLoading {
    @MainActor
    static func wait(_ label: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if condition() { return }
        } while Date() < deadline
        fatalError("Timed out: \(label)")
    }

    @MainActor
    static func main() {
        _ = NSApplication.shared
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
        from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
        import time
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                if self.path.startswith('/pending'):
                    time.sleep(30)
                    return
                if self.path.startswith('/fail'):
                    self.connection.close()
                    return
                data = b'<html><title>Loaded</title><body>Ready</body></html>'
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """]
        let pipe = Pipe()
        server.standardOutput = pipe
        try! server.run()
        defer { server.terminate() }
        let port = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = BrowserTab(isPrivate: true)
        let view = tab.ensureWebView()
        func navigate(_ path: String) {
            view.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)?nonce=\(UUID())")!))
        }
        navigate("pending")
        wait("start", until: { tab.isLoading })
        tab.stopLoading()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        precondition(!tab.isLoading, "Stop must not be undone by queued engine callbacks")
        navigate("pending")
        wait("restart", until: { tab.isLoading })
        navigate("done")
        wait("superseding navigation finishes", until: { !tab.isLoading && view.title == "Loaded" })
        navigate("pending")
        wait("before failure", until: { tab.isLoading })
        navigate("fail")
        wait("failure", until: { !tab.isLoading && !view.isLoading })
        navigate("pending")
        wait("before teardown", until: { tab.isLoading })
        tab.tearDown()
        wait("teardown", until: { !tab.isLoading && tab.webView == nil })
        print("navigation-loading-tests=passed")
    }
}
