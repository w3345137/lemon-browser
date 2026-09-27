import AppKit
import WebKit

@main
enum TestPrivateSession {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let session = WKWebsiteDataStore.nonPersistent()
        let a = BrowserTab(isPrivate: true, dataStore: session)
        let b = BrowserTab(isPrivate: true, dataStore: session)
        let c = BrowserTab(isPrivate: true, dataStore: .nonPersistent())
        let first = a.ensureWebView().configuration.websiteDataStore
        let second = b.ensureWebView().configuration.websiteDataStore
        precondition(first === second && !first.isPersistent)
        let cookie = HTTPCookie(properties: [.domain: "example.test", .path: "/", .name: "session", .value: "fixture"])!
        await first.httpCookieStore.setCookie(cookie)
        let shared = await second.httpCookieStore.allCookies()
        let separate = await c.ensureWebView().configuration.websiteDataStore.httpCookieStore.allCookies()
        precondition(shared.contains { $0.name == "session" })
        precondition(!separate.contains { $0.name == "session" })
        a.tearDown(); b.tearDown(); c.tearDown()
        print("private-session-tests=passed")
    }
}
