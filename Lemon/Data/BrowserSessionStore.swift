import Foundation

struct ClosedTabSnapshot: Codable, Equatable {
    var url: URL
    var title: String
    var scrollX: Double?
    var scrollY: Double?
    /// 旧版会话没有此字段；可选解码保证回滚兼容。
    var isPinned: Bool?

    init(url: URL, title: String, scrollX: Double? = nil, scrollY: Double? = nil, isPinned: Bool? = nil) {
        self.url = url
        self.title = title
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.isPinned = isPinned
    }
}

struct BrowserSessionSnapshot: Codable {
    struct TabSnapshot: Codable {
        var url: URL?
        var title: String
        var isPinned: Bool
        var scrollX: Double?
        var scrollY: Double?
    }

    var tabs: [TabSnapshot]
    var selectedIndex: Int
    var closedTabs: [ClosedTabSnapshot]

    enum CodingKeys: String, CodingKey {
        case tabs, selectedIndex, closedTabs
    }

    init(tabs: [TabSnapshot], selectedIndex: Int, closedTabs: [ClosedTabSnapshot]) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.closedTabs = closedTabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decode([TabSnapshot].self, forKey: .tabs)
        selectedIndex = try container.decode(Int.self, forKey: .selectedIndex)
        if let items = try? container.decode([ClosedTabSnapshot].self, forKey: .closedTabs) {
            closedTabs = items
        } else if let urls = try? container.decode([URL].self, forKey: .closedTabs) {
            closedTabs = urls.map { ClosedTabSnapshot(url: $0, title: "") }
        } else {
            closedTabs = []
        }
    }
}

/// 会话文件按窗口分桶：每个普通窗口持有稳定 UUID，读写只替换自己的记录。
/// 旧版单窗口 session.json 在读取时一次性包装成窗口记录，写回时升级格式。
struct BrowserSessionFile: Codable {
    struct WindowRecord: Codable {
        var id: String
        var updatedAt: Date
        var snapshot: BrowserSessionSnapshot
    }

    var windows: [WindowRecord]

    /// 磁盘上保留的最近窗口记录上限，避免反复创建窗口后文件无限增长。
    static let maxWindowRecords = 10
}

enum BrowserSessionStore {
    /// 测试专用：覆盖后所有读写都落到临时文件，不触碰真实会话。
    static var overrideSessionURL: URL?

    private static var sessionURL: URL {
        if let overrideSessionURL { return overrideSessionURL }
        let folder = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Lumen", isDirectory: true) // Legacy namespace preserves existing profiles.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("session.json")
    }

    private static func loadFile() -> BrowserSessionFile {
        guard let data = try? Data(contentsOf: sessionURL) else {
            return BrowserSessionFile(windows: [])
        }
        if let file = try? JSONDecoder().decode(BrowserSessionFile.self, from: data) {
            return file
        }
        // 旧版格式：整个文件就是一个窗口的会话快照。
        if let legacy = try? JSONDecoder().decode(BrowserSessionSnapshot.self, from: data),
           !legacy.tabs.isEmpty {
            return BrowserSessionFile(windows: [
                .init(id: "legacy", updatedAt: .distantPast, snapshot: legacy)
            ])
        }
        return BrowserSessionFile(windows: [])
    }

    /// 启动或新建普通窗口时认领一条尚未被使用的窗口会话。
    /// 返回 nil 表示没有可恢复的会话，调用方应给窗口分配新 ID。
    static func claimRestorableSession(claimedIDs: Set<String>) -> (windowID: String, snapshot: BrowserSessionSnapshot)? {
        let candidates = loadFile().windows
            .filter { !claimedIDs.contains($0.id) && !$0.snapshot.tabs.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let record = candidates.first else { return nil }
        return (record.id, record.snapshot)
    }

    static func save(windowID: String, snapshot: BrowserSessionSnapshot) {
        var file = loadFile()
        let record = BrowserSessionFile.WindowRecord(id: windowID, updatedAt: Date(), snapshot: snapshot)
        if let index = file.windows.firstIndex(where: { $0.id == windowID }) {
            file.windows[index] = record
        } else {
            file.windows.append(record)
        }
        file.windows.sort { $0.updatedAt > $1.updatedAt }
        if file.windows.count > BrowserSessionFile.maxWindowRecords {
            file.windows = Array(file.windows.prefix(BrowserSessionFile.maxWindowRecords))
        }
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: sessionURL, options: .atomic)
    }
}
