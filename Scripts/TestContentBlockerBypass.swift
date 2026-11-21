import AppKit
import WebKit

@main enum TestContentBlockerBypass {
    @MainActor static func wait(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(condition(), message)
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
        from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                if self.path == '/redirect':
                    self.send_response(302)
                    self.send_header('Location','http://localhost:%d/final' % self.server.server_port)
                    self.end_headers()
                    return
                data=b'<title>allowed-fixture</title><body>local only</body>'
                self.send_response(200)
                self.send_header('Content-Type','text/html')
                self.send_header('Content-Length',str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            do_POST=do_GET
        s=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        print(s.server_port,flush=True)
        s.serve_forever()
        """]
        let pipe = Pipe(); server.standardOutput = pipe
        try server.run(); defer { server.terminate() }
        let port = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = WKContentRuleListStore.default()!
        let identifier = "lemon-bypass-fixture-\(UUID().uuidString)"
        var compiled = false
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList:
            #"[{"trigger":{"url-filter":"^http://127\\.0\\.0\\.1:"},"action":{"type":"block"}}]"#) { list, error in
                precondition(error == nil)
                ContentBlocker.shared.fixtureRule = list
                compiled = true
            }
        wait("compile local fixture") { compiled }
        defer {
            ContentBlocker.shared.fixtureRule = nil
            store.removeContentRuleList(forIdentifier: identifier) { _ in }
        }
        let destination = URL(string: "http://127.0.0.1:\(port)/page?token=synthetic-only")!
        let first = BrowserTab(isPrivate: true, startURL: destination)
        let second = BrowserTab(isPrivate: true, startURL: destination)
        defer { first.tearDown(); second.tearDown() }
        wait("blocked tabs offer manual action") { first.canAllowBlockedPage && second.canAllowBlockedPage }
        first.allowBlockedPage()
        wait("manual allowance loads") { first.title == "allowed-fixture" && !first.isLoading }
        precondition(first.contentBlockingBypassURL == destination && first.navigationError == nil)
        precondition(second.canAllowBlockedPage && second.contentBlockingBypassURL == nil)
        let popupConfig = WKWebViewConfiguration()
        popupConfig.userContentController = first.webView!.configuration.userContentController
        let popup = BrowserTab(isPrivate: true)
        let popupView = popup.adoptPopupWebView(configuration: popupConfig)
        precondition(popupView.configuration.userContentController !== first.webView!.configuration.userContentController)
        popupView.load(URLRequest(url: destination))
        wait("new popup retains blocking") { popup.canAllowBlockedPage }
        popup.tearDown()
        precondition(first.contentBlockingBypassURL == destination)
        first.reload()
        wait("reload restores blocking") { first.canAllowBlockedPage }
        precondition(first.contentBlockingBypassURL == nil)
        first.allowBlockedPage()
        wait("allow again") { first.title == "allowed-fixture" && !first.isLoading }
        first.webView!.load(URLRequest(url: URL(string: "http://localhost:\(port)/other")!))
        wait("new origin restores rules") { first.contentBlockingBypassURL == nil && !first.isLoading }
        first.load(destination)
        wait("return to blocked origin blocked again") { first.canAllowBlockedPage }
        let beforeRedirect = first.navigationRevision
        first.load(URL(string: "http://127.0.0.1:\(port)/redirect")!)
        wait("redirect entry initially blocked") { first.navigationRevision != beforeRedirect && first.canAllowBlockedPage }
        first.allowBlockedPage()
        wait("cross-origin server redirect revokes allowance") {
            first.url?.host == "localhost" && first.contentBlockingBypassURL == nil && !first.isLoading
        }
        var post = URLRequest(url: destination); post.httpMethod = "POST"; post.httpBody = Data("private=synthetic".utf8)
        let beforePost = first.navigationRevision
        first.webView!.load(post)
        wait("POST blocked") { first.navigationRevision != beforePost && first.isContentBlocked && !first.isLoading }
        precondition(!first.canAllowBlockedPage, "must not replay form submissions")
        precondition(!BrowserTab.isContentBlockerError(NSError(domain: NSURLErrorDomain, code: -1202)))
        precondition(!BrowserTab.isContentBlockerError(NSError(domain: "OtherDomain", code: 104)))
        first.tearDown()
        precondition(first.contentBlockingBypassURL == nil)
        print("content-blocker-bypass-tab-isolation-reload-origin-popup-post-safety=passed")
    }
}
