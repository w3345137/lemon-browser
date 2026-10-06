import AppKit
import WebKit

@available(macOS 15.4, *)
@MainActor private final class FixtureWindow: NSObject, WKWebExtensionWindow, WKWebExtensionControllerDelegate {
    var tab: FixtureTab?
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tab.map { [$0] } ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [self] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
}

@available(macOS 15.4, *)
@MainActor private final class FixtureTab: NSObject, WKWebExtensionTab {
    let view: WKWebView
    weak var owner: FixtureWindow?
    init(_ view: WKWebView, owner: FixtureWindow) { self.view = view; self.owner = owner }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { view }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
}

@main enum TestMicrosoftLoginDNR {
    @MainActor static func check(_ view: WKWebView, _ source: String) async throws {
        let result = try await view.evaluateJavaScript(source)
        if result as? Bool != true {
            let diagnostic = try await view.evaluateJavaScript("JSON.stringify({url:location.href,ready:document.readyState,loaded:window.fixtureLoaded||0,inputs:document.querySelectorAll('input').length,resources:performance.getEntriesByType('resource').map(x=>x.name)})")
            throw NSError(domain: "TestMicrosoftLoginDNR", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(source): \(diagnostic ?? "nil")"])
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let resources = MicrosoftLoginResourcePolicy.resourcesURL!
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("manifest.json"))) as! [String: Any]
        let rules = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("rules.json"))) as! [[String: Any]]
        precondition((manifest["permissions"] as? [String]) == ["declarativeNetRequestWithHostAccess"])
        precondition((manifest["host_permissions"] as? [String])?.count == 4)
        precondition(rules.count == 2)
        for rule in rules {
            let redirect = (rule["action"] as! [String: Any])["redirect"] as! [String: Any]
            precondition(redirect["regexSubstitution"] as? String == "https://aadcdn.msauth.net/\\1")
            let conditions = rule["condition"] as! [String: Any]
            precondition(Set(conditions["resourceTypes"] as! [String]) == ["script", "stylesheet"])
            precondition(conditions["initiatorDomains"] == nil && conditions["requestMethods"] == nil)
        }
        for raw in ["https://login.microsoftonline.com/common/login", "https://login.windows.net/common/login"] {
            precondition(MicrosoftLoginResourcePolicy.applies(to: URL(string: raw)!))
        }
        for raw in ["http://login.microsoftonline.com/", "https://login.microsoftonline.com.evil.example/", "https://login.microsoftonline.com:8443/", "https://partner.microsoft.com/"] {
            precondition(!MicrosoftLoginResourcePolicy.applies(to: URL(string: raw)!))
        }
        guard #available(macOS 15.4, *) else { print("DNR unavailable on this OS; scope tests passed"); return }
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
        from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
        import time
        class H(BaseHTTPRequestHandler):
            def log_message(self,*a): pass
            def do_GET(self):
                if self.path == '/login':
                    body=("<script src='http://127.0.0.1:"+str(self.server.server_port)+"/shared/hang.js'></script><input value='preserve'>").encode()
                    self.send_response(200);self.send_header('Content-Type','text/html');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
                if self.path.endswith('hang.js') and self.headers.get('Host','').startswith('127.0.0.1'): time.sleep(2)
                body=b'window.fixtureLoaded=(window.fixtureLoaded||0)+1;'
                self.send_response(200)
                self.send_header('Content-Type','application/javascript')
                self.send_header('Access-Control-Allow-Origin','*')
                self.send_header('Content-Length',str(len(body))); self.end_headers()
                try: self.wfile.write(body)
                except: pass
        s=ThreadingHTTPServer(('127.0.0.1',0),H);print(s.server_port,flush=True);s.serve_forever()
        """]
        let pipe = Pipe(); server.standardOutput = pipe
        try server.run(); defer { server.terminate() }
        let port = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("lemon-dnr-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let fixtureManifest: [String: Any] = ["manifest_version": 3, "name": "Lemon DNR local fixture", "description": "Local static resource redirect fixture", "version": "1.0", "permissions": ["declarativeNetRequestWithHostAccess"], "host_permissions": ["http://127.0.0.1/*", "http://localhost/*"], "declarative_net_request": ["rule_resources": [["id": "fixture", "enabled": true, "path": "rules.json"]]]]
        let fixtureRule: [[String: Any]] = [["id": 1, "priority": 1, "action": ["type": "redirect", "redirect": ["regexSubstitution": "http://localhost:\(port)/\\1"]], "condition": ["regexFilter": "^http://127\\.0\\.0\\.1:\(port)/(.*)", "resourceTypes": ["script"]]]]
        try JSONSerialization.data(withJSONObject: fixtureManifest).write(to: fixture.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: fixtureRule).write(to: fixture.appendingPathComponent("rules.json"))
        let ext = try await WKWebExtension(resourceBaseURL: fixture)
        precondition(ext.errors.isEmpty)
        let context = WKWebExtensionContext(for: ext); context.hasAccessToPrivateData = true
        context.setPermissionStatus(.grantedExplicitly, for: .declarativeNetRequestWithHostAccess)
        for host in ["127.0.0.1", "localhost"] {
            context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "http://\(host)/*"))
        }
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let owner = FixtureWindow(); controller.delegate = owner
        try controller.load(context)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.webExtensionController = controller
        let view = WKWebView(frame: NSRect(x: 0,y: 0,width: 800,height: 600), configuration: config)
        let tab = FixtureTab(view, owner: owner); owner.tab = tab
        controller.didOpenWindow(owner); controller.didOpenTab(tab); controller.didActivateTab(tab, previousActiveTab: nil)
        view.load(URLRequest(url: URL(string: "http://localhost:\(port)/login")!))
        try await Task.sleep(nanoseconds: 1_400_000_000)
        try await check(view, "window.fixtureLoaded===1 && document.querySelector('input').value==='preserve'")
        try await Task.sleep(nanoseconds: 2_200_000_000)
        try await check(view, "window.fixtureLoaded===1")
        view.stopLoading(); try controller.unload(context)
        print("microsoft-login-dnr-tests=passed")
    }
}
