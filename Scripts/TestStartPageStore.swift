import Foundation

@main
struct TestStartPageStore {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lemon-start-page-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("profile/start-page.json")
        let store = StartPageStore(storageURL: url)
        precondition(!FileManager.default.fileExists(atPath: url.path))
        precondition(store.configuration.visibleModules == Set(StartPageModule.allCases))
        let a = try store.saveShortcut(title: "  测试网页  ", address: "example.com/path?q=test#anchor")
        precondition(a.title == "测试网页" && a.url.absoluteString == "https://example.com/path?q=test#anchor")
        let b = try store.saveShortcut(title: "", address: "http://localhost:8080/page")
        precondition(b.title == "localhost")
        try store.moveShortcut(b.id, by: -1)
        precondition(store.configuration.shortcuts.map(\.id) == [b.id, a.id])
        try store.moveShortcut(b.id, by: -100)
        precondition(store.configuration.shortcuts.first?.id == b.id)
        try store.saveShortcut(id: a.id, title: "更新后的名称", address: "https://new.example/path")
        precondition(store.configuration.shortcuts.last?.id == a.id)
        precondition(store.configuration.shortcuts.last?.title == "更新后的名称")
        for module in StartPageModule.allCases { try store.setVisible(module, false) }
        precondition(store.configuration.visibleModules.isEmpty && store.configuration.shortcuts.count == 2)
        let persisted = StartPageStore(storageURL: url)
        precondition(persisted.configuration == store.configuration)
        try store.restoreModules()
        precondition(store.configuration.shortcuts.count == 2)
        try store.setVisible(.shortcuts, false)
        try store.saveShortcut(title: "再添加", address: "//other.example/")
        precondition(store.isVisible(.shortcuts))
        let original = store.configuration
        for bad in ["", "not a url", "javascript://example.com/test", "javascript:alert(1)",
                    "file:///Users/test/a.html", "data:text/html,hello", "https://", "https://user:pass@example.com"] {
            do { try store.saveShortcut(title: "bad", address: bad); preconditionFailure("accepted \(bad)") }
            catch { precondition(store.configuration == original) }
        }
        do { try store.saveShortcut(title: "duplicate", address: b.url.absoluteString); preconditionFailure("duplicate") }
        catch { precondition(store.configuration == original) }
        do { try store.saveShortcut(id: UUID(), title: "missing", address: "https://missing.example"); preconditionFailure("missing") }
        catch { precondition(store.configuration == original) }
        try store.removeShortcut(a.id)
        precondition(!store.configuration.shortcuts.contains { $0.id == a.id })
        precondition(StartPageStore(storageURL: url).configuration == store.configuration)

        let transientURL = root.appendingPathComponent("not-created/start-page.json")
        let transient = StartPageStore(storageURL: transientURL, inMemory: true)
        let otherTransient = StartPageStore(inMemory: true)
        try transient.saveShortcut(title: "临时网页", address: "https://temporary.example")
        try transient.setVisible(.favorites, false)
        precondition(!FileManager.default.fileExists(atPath: transientURL.deletingLastPathComponent().path))
        precondition(otherTransient.configuration.shortcuts.isEmpty && otherTransient.isVisible(.favorites))

        // 不覆盖损坏/未知版本配置；保存失败不先更新内存，也不丢原数据。
        let brokenURL = root.appendingPathComponent("broken.json")
        let brokenData = Data("{broken".utf8)
        try brokenData.write(to: brokenURL)
        let broken = StartPageStore(storageURL: brokenURL)
        precondition(broken.storageError != nil)
        do { try broken.setVisible(.favorites, false); preconditionFailure("overwrote corrupt data") }
        catch {
            let preserved = try Data(contentsOf: brokenURL)
            precondition(preserved == brokenData)
        }
        let blocker = root.appendingPathComponent("blocker")
        let writeFailure = StartPageStore(storageURL: blocker.appendingPathComponent("start-page.json"))
        try Data("file, not directory".utf8).write(to: blocker)
        let unchanged = writeFailure.configuration
        do { try writeFailure.saveShortcut(title: "x", address: "https://write.example"); preconditionFailure("unexpected write") }
        catch { precondition(writeFailure.configuration == unchanged && writeFailure.storageError != nil) }
        print("start-page-persistence-module-shortcut-validation-and-isolation-tests=passed")
    }
}
