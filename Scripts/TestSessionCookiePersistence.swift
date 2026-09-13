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

        let legacyURL = folder.appendingPathComponent("legacy.enc")
        let legacyKey = SymmetricKey(size: .bits256)
        let legacyStore = WKWebsiteDataStore.nonPersistent()
        let legacyWriter = SessionCookieVault(cookieStore: legacyStore.httpCookieStore, archiveURL: legacyURL, key: legacyKey)
        await withCheckedContinuation { c in legacyWriter.prepare { c.resume() } }
        await legacyStore.httpCookieStore.setCookie(cookie)
        await withCheckedContinuation { c in legacyWriter.flush { c.resume() } }
        legacyWriter.stopObserving()
        let preservedLegacy = try Data(contentsOf: legacyURL)

        let migratedURL = folder.appendingPathComponent("migrated.enc")
        let migratedKey = SymmetricKey(size: .bits256)
        let migrationStore = WKWebsiteDataStore.nonPersistent()
        let migration = SessionCookieVault(
            cookieStore: migrationStore.httpCookieStore,
            archiveURL: migratedURL,
            key: migratedKey,
            legacyArchiveURL: legacyURL,
            legacyKey: legacyKey
        )
        await withCheckedContinuation { c in migration.prepare { c.resume() } }
        let migratedCookies = await migrationStore.httpCookieStore.allCookies()
        precondition(migratedCookies.contains { $0.name == "login" })
        await withCheckedContinuation { c in migration.flush { c.resume() } }
        precondition(migration.storageError == nil)
        precondition(FileManager.default.fileExists(atPath: migratedURL.path))
        let legacyAfterMigration = try Data(contentsOf: legacyURL)
        precondition(legacyAfterMigration == preservedLegacy, "Legacy archive must remain untouched")
        migration.stopObserving()

        // An archive encrypted by an inaccessible former signing identity must
        // not permanently disable new saves or repeatedly block app shutdown.
        let fallbackURL = folder.appendingPathComponent("fallback.enc")
        let fallbackStore = WKWebsiteDataStore.nonPersistent()
        let fallback = SessionCookieVault(
            cookieStore: fallbackStore.httpCookieStore,
            archiveURL: fallbackURL,
            key: SymmetricKey(size: .bits256),
            legacyArchiveURL: legacyURL,
            legacyKey: SymmetricKey(size: .bits256)
        )
        await withCheckedContinuation { c in fallback.prepare { c.resume() } }
        await fallbackStore.httpCookieStore.setCookie(cookie)
        await withCheckedContinuation { c in fallback.flush { c.resume() } }
        precondition(fallback.storageError == nil)
        precondition(FileManager.default.fileExists(atPath: fallbackURL.path))
        let legacyAfterFallback = try Data(contentsOf: legacyURL)
        precondition(legacyAfterFallback == preservedLegacy, "Inaccessible legacy archive must remain untouched")
        fallback.stopObserving()
        print("session-cookie-persistence-tests=passed")
    }
}
