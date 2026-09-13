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
        precondition(BrowserTabTitle.display(documentTitle: "话题", url: URL(string: "https://www.zhihu.com/topic/123")) == "话题")
        precondition(BrowserTabTitle.display(documentTitle: "", url: URL(string: "https://www.zhihu.com/topic/123")) == "zhihu.com/topic/123")
        precondition(BrowserTabTitle.display(documentTitle: nil, url: URL(string: "about:blank")) == "新标签页")
        precondition(BrowserTabTitle.display(documentTitle: "  ", url: nil) == "新标签页")
        precondition(BrowserTabTitle.display(documentTitle: nil, url: URL(fileURLWithPath: "/tmp/本地网页.html")) == "本地网页.html")
        precondition(BrowserTabTitle.display(documentTitle: nil, url: URL(string: "https://user:secret@www.example.com:443/")) == "example.com")
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
                data = b'<html><title>Loaded</title><body style="height:5000px">Ready<div id="inner" style="height:100px;overflow:auto"><div style="height:3000px">Inner</div></div></body></html>'
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
        view.setFrameSize(NSSize(width: 800, height: 600))
        var scrolled = false
        view.evaluateJavaScript("window.scrollTo(0,800);document.getElementById('inner').scrollTop=300;window.scrollY") { value, error in
            precondition(error == nil && (value as? Double ?? 0) > 0)
            scrolled = true
        }
        wait("scroll fixture", until: { scrolled })
        tab.restoreScroll(CGPoint(x: 0, y: 800))
        tab.reload()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        wait("reload finishes", until: { !tab.isLoading })
        var checked = false
        view.evaluateJavaScript("[window.scrollY,document.getElementById('inner').scrollTop]") { value, error in
            precondition(error == nil && (value as? [Double]) == [0, 0], "Refresh must return to top")
            checked = true
        }
        wait("reload scroll reset", until: { checked })
        view.evaluateJavaScript("document.title='动态话题标题'")
        wait("dynamic title", until: { tab.title == "动态话题标题" })
        view.evaluateJavaScript("document.title=''")
        wait("empty title falls back to URL", until: {
            tab.title == BrowserTabTitle.display(documentTitle: nil, url: view.url)
        })
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
