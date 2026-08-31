import Foundation

@main
struct TestBrowserSession {
    static func main() throws {
        let expected = BrowserSessionSnapshot(
            tabs: [
                .init(
                    url: URL(string: "https://example.com/one")!,
                    title: "One",
                    isPinned: true,
                    scrollX: 12,
                    scrollY: 340
                ),
                .init(url: URL(string: "https://example.com/two")!, title: "Two", isPinned: false),
                .init(url: nil, title: "起始页面", isPinned: false)
            ],
            selectedIndex: 1,
            closedTabs: [
                ClosedTabSnapshot(
                    url: URL(string: "https://example.com/closed")!,
                    title: "Closed",
                    scrollX: 0,
                    scrollY: 88
                )
            ]
        )

        let data = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(BrowserSessionSnapshot.self, from: data)

        precondition(decoded.tabs.count == 3)
        precondition(decoded.tabs[0].isPinned)
        precondition(decoded.tabs[0].scrollY == 340)
        precondition(decoded.tabs[1].url?.host == "example.com")
        precondition(decoded.tabs[2].url == nil)
        precondition(decoded.selectedIndex == 1)
        precondition(decoded.closedTabs.first?.url.lastPathComponent == "closed")
        precondition(decoded.closedTabs.first?.title == "Closed")
        precondition(decoded.closedTabs.first?.scrollY == 88)

        let legacy = Data("""
        {"tabs":[{"url":"https://example.com/one","title":"One","isPinned":true}],"selectedIndex":0,"closedTabs":["https://example.com/closed"]}
        """.utf8)
        let migrated = try JSONDecoder().decode(BrowserSessionSnapshot.self, from: legacy)
        precondition(migrated.closedTabs.first?.url.lastPathComponent == "closed")
        precondition(migrated.tabs[0].scrollX == nil)

        // 多窗口会话：每个窗口按 ID 写自己的记录，认领跳过已被占用的窗口。
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemon-session-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        BrowserSessionStore.overrideSessionURL = tempDir.appendingPathComponent("session.json")

        let windowA = BrowserSessionSnapshot(
            tabs: [.init(url: URL(string: "https://a.example.com/")!, title: "A", isPinned: false)],
            selectedIndex: 0,
            closedTabs: []
        )
        let windowB = BrowserSessionSnapshot(
            tabs: [.init(url: URL(string: "https://b.example.com/")!, title: "B", isPinned: true)],
            selectedIndex: 0,
            closedTabs: []
        )
        BrowserSessionStore.save(windowID: "window-a", snapshot: windowA)
        BrowserSessionStore.save(windowID: "window-b", snapshot: windowB)

        // 后保存的 B 是最新记录，先被认领。
        let first = BrowserSessionStore.claimRestorableSession(claimedIDs: [])
        precondition(first?.windowID == "window-b")
        precondition(first?.snapshot.tabs.first?.title == "B")

        // 已被活窗口认领的记录不会分配给第二个窗口。
        let second = BrowserSessionStore.claimRestorableSession(claimedIDs: ["window-b"])
        precondition(second?.windowID == "window-a")
        precondition(BrowserSessionStore.claimRestorableSession(claimedIDs: ["window-a", "window-b"]) == nil)

        // 同 ID 再写只更新自己的记录，另一条不受影响。
        let windowBUpdated = BrowserSessionSnapshot(
            tabs: [
                .init(url: URL(string: "https://b.example.com/")!, title: "B", isPinned: true),
                .init(url: URL(string: "https://b2.example.com/")!, title: "B2", isPinned: false)
            ],
            selectedIndex: 1,
            closedTabs: []
        )
        BrowserSessionStore.save(windowID: "window-b", snapshot: windowBUpdated)
        let afterUpdate = BrowserSessionStore.claimRestorableSession(claimedIDs: ["window-b"])
        precondition(afterUpdate?.snapshot.tabs.first?.title == "A")

        // 旧版单窗口文件读取时包装成可认领的窗口记录。
        try legacy.write(to: BrowserSessionStore.overrideSessionURL!)
        let legacyClaim = BrowserSessionStore.claimRestorableSession(claimedIDs: [])
        precondition(legacyClaim?.snapshot.tabs.first?.title == "One")
        precondition(legacyClaim?.snapshot.closedTabs.first?.url.lastPathComponent == "closed")

        // 认领后按同一 ID 写回，文件升级为多窗口格式且可再次认领。
        BrowserSessionStore.save(windowID: legacyClaim!.windowID, snapshot: legacyClaim!.snapshot)
        let reclaimed = BrowserSessionStore.claimRestorableSession(claimedIDs: [])
        precondition(reclaimed?.snapshot.tabs.first?.title == "One")

        // 超过上限的旧记录被裁掉，文件不会无限增长。
        for index in 0..<(BrowserSessionFile.maxWindowRecords + 5) {
            BrowserSessionStore.save(windowID: "extra-\(index)", snapshot: windowA)
        }
        let fileData = try Data(contentsOf: BrowserSessionStore.overrideSessionURL!)
        let file = try JSONDecoder().decode(BrowserSessionFile.self, from: fileData)
        precondition(file.windows.count == BrowserSessionFile.maxWindowRecords)

        print("browser-session-tests=passed")
    }
}
