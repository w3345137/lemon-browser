import AppKit
import CryptoKit
import WebKit

@main
struct TestSessionCookiePersistence {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cookies.enc")
        let key = SymmetricKey(size: .bits256)
        let first = WKWebsiteDataStore.nonPersistent()
        let vault = SessionCookieVault(cookieStore: first.httpCookieStore, archiveURL: url, key: key)
        await withCheckedContinuation { c in vault.prepare { c.resume() } }
        let cookie = HTTPCookie(properties: [.name: "login", .value: "fixture", .domain: "example.test", .path: "/", .discard: "TRUE", .secure: "TRUE", HTTPCookiePropertyKey(rawValue: "HttpOnly"): "TRUE"])!
        await first.httpCookieStore.setCookie(cookie)
        await withCheckedContinuation { c in vault.flush { c.resume() } }
        precondition(vault.storageError == nil)
        vault.stopObserving()
        let encrypted = try Data(contentsOf: url)
        precondition(!String(decoding: encrypted, as: UTF8.self).contains("fixture"))
        let second = WKWebsiteDataStore.nonPersistent()
        let restored = SessionCookieVault(cookieStore: second.httpCookieStore, archiveURL: url, key: key)
        await withCheckedContinuation { c in restored.prepare { c.resume() } }
        let result = await second.httpCookieStore.allCookies()
        precondition(result.contains { $0.name == "login" && $0.value == "fixture" && $0.isHTTPOnly })
        await second.httpCookieStore.delete(result.first!)
        // WebKit's cookie enumeration can lag the delete completion by one IPC turn.
        var afterDeletion = await second.httpCookieStore.allCookies()
        for _ in 0..<30 where !afterDeletion.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
            afterDeletion = await second.httpCookieStore.allCookies()
        }
        precondition(afterDeletion.isEmpty)
        await withCheckedContinuation { c in restored.flush { c.resume() } }
        restored.stopObserving()
        let third = WKWebsiteDataStore.nonPersistent()
        let loggedOut = SessionCookieVault(cookieStore: third.httpCookieStore, archiveURL: url, key: key)
        await withCheckedContinuation { c in loggedOut.prepare { c.resume() } }
        let empty = await third.httpCookieStore.allCookies()
        precondition(empty.isEmpty, "Logout must not resurrect a session")
        await withCheckedContinuation { c in loggedOut.flush { c.resume() } }
        loggedOut.stopObserving()
        let before = try Data(contentsOf: url)
        let invalid = SessionCookieVault(cookieStore: WKWebsiteDataStore.nonPersistent().httpCookieStore, archiveURL: url, key: SymmetricKey(size: .bits256))
        await withCheckedContinuation { c in invalid.prepare { c.resume() } }
        await withCheckedContinuation { c in invalid.flush { c.resume() } }
        let after = try Data(contentsOf: url)
        precondition(before == after, "Unreadable archives must be preserved")
        precondition(invalid.storageError != nil)
        print("session-cookie-persistence-tests=passed")
    }
}
