import AppKit
import WebKit

@MainActor final class Navigation: NSObject, WKNavigationDelegate {
    var finished = false
    var error: NSError?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error as NSError
    }
}

@main enum TestContentBlockerNavigation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
        from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                data=b'<title>navigation-ok</title><body>local fixture</body>'
                self.send_response(200)
                self.send_header('Content-Length',str(len(data)))
                self.send_header('Content-Type','text/html')
                self.end_headers()
                self.wfile.write(data)
        s=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        print(s.server_port,flush=True)
        s.serve_forever()
        """]
        let pipe = Pipe(); server.standardOutput = pipe
        try server.run()
        defer { server.terminate() }
        let port = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = WKContentRuleListStore.default()!
        func compile(_ json: String) async throws -> WKContentRuleList {
            try await withCheckedThrowingContinuation { c in
                store.compileContentRuleList(forIdentifier: "lemon-local-\(UUID().uuidString)", encodedContentRuleList: json) { list, error in
                    if let list { c.resume(returning: list) } else { c.resume(throwing: error!) }
                }
            }
        }
        let realRules = try await compile(ContentBlockerRules.jsonString())
        // The same generated hostname matcher, pointed only at our loopback fixture.
        let hostFilter = ContentBlockerRules.blockedURLFilters.first { $0.contains("l\\.qq\\.com") }!
            .replacingOccurrences(of: "l\\.qq\\.com", with: "127\\.0\\.0\\.1")
        let data = try JSONSerialization.data(withJSONObject: [["trigger": ["url-filter": hostFilter], "action": ["type": "block"]]])
        let loopbackRule = try await compile(String(data: data, encoding: .utf8)!)
        for (list, shouldBlock) in [(realRules, false), (loopbackRule, true)] {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(list)
            let view = WKWebView(frame: .zero, configuration: config)
            let nav = Navigation(); view.navigationDelegate = nav
            view.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/l.qq.com/?next=https://doubleclick.net/")!))
            for _ in 0..<100 {
                if nav.finished || nav.error != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if shouldBlock {
                precondition(nav.error?.domain == "WebKitErrorDomain" && nav.error?.code == 104, "must block actual hostname: \(String(describing: nav.error))")
                print("webkit-real-host-block=passed code=104")
            } else {
                precondition(nav.finished && nav.error == nil, "must allow ad-domain strings in path/query")
                precondition(view.title == "navigation-ok")
                print("webkit-path-query-not-blocked=passed")
            }
            view.stopLoading()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                store.removeContentRuleList(forIdentifier: list.identifier) { _ in c.resume() }
            }
        }
    }
}
