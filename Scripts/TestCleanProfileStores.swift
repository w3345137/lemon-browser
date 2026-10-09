import Foundation
import WebKit

/// 使用虚构凭据及随机临时文件，不访问个人钥匙串或共享资料。
@main
struct TestCleanProfileStores {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lemon-profile-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("history.json")
        let personalHistory = HistoryStore(isPrivate: false, storageURL: historyURL)
        let personalURL = URL(string: "https://personal.example/profile")!
        personalHistory.record(title: "Private test record", url: personalURL)
        let before = try Data(contentsOf: historyURL)
        let history = HistoryStore(isPrivate: false, storageURL: historyURL, inMemory: true)
        precondition(history.entries.isEmpty)
        let demoURL = URL(string: "https://public.example/test")!
        history.record(title: "Public test record", url: demoURL)
        precondition(history.search("public").count == 1)
        let afterRecord = try Data(contentsOf: historyURL)
        precondition(afterRecord == before)
        history.clear()
        let afterClear = try Data(contentsOf: historyURL)
        precondition(afterClear == before)
        precondition(HistoryStore(isPrivate: false, storageURL: historyURL, inMemory: true).entries.isEmpty)

        let a = CredentialStore(inMemory: true)
        let b = CredentialStore(inMemory: true)
        let scope = "https://public.example"
        let credential = WebCredential(scope: scope, username: "test-user")
        precondition(a.credentials.isEmpty && b.credentials.isEmpty)
        precondition(a.saveDecision(scope: scope, username: credential.username, password: "fake-password") == .save)
        try a.save(scope: scope, username: credential.username, password: "fake-password")
        let savedPassword = try a.password(for: credential)
        precondition(savedPassword == "fake-password")
        precondition(a.credentials(for: demoURL) == [credential])
        precondition(a.saveDecision(scope: scope, username: credential.username, password: "fake-password") == .unchanged)
        precondition(a.saveDecision(scope: scope, username: credential.username, password: "different") == .update)
        precondition(b.credentials.isEmpty)
        do { _ = try b.password(for: credential); preconditionFailure("other profile leaked password") }
        catch {}
        try a.delete(credential)
        precondition(a.credentials.isEmpty)

        let originalPermissions = UserDefaults.standard.data(forKey: "sitePermissions.v1")
        let p = SitePermissionStore(inMemory: true)
        let q = SitePermissionStore(inMemory: true)
        p.set(.allow, for: "public.example", kind: .camera)
        p.setExternalApplicationChoice(.block, for: "public.example", scheme: "test")
        precondition(p.choice(for: "public.example", kind: .camera) == .allow)
        precondition(q.choice(for: "public.example", kind: .camera) == .ask)
        precondition(q.externalApplicationChoice(for: "public.example", scheme: "test") == .ask)
        p.resetAll()
        precondition(p.configuredHosts.isEmpty)
        precondition(UserDefaults.standard.data(forKey: "sitePermissions.v1") == originalPermissions)
        print("clean-profile-history-credential-permission-isolation=passed")
    }
}
