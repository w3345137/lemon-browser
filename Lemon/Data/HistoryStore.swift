import Foundation

struct HistoryEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var url: URL
    var visitedAt: Date

    init(id: UUID = UUID(), title: String, url: URL, visitedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore(isPrivate: false)
    @Published private(set) var entries: [HistoryEntry] = []

    private let url: URL
    private let isPrivate: Bool

    init(isPrivate: Bool, storageURL: URL? = nil) {
        self.isPrivate = isPrivate
        if let storageURL {
            url = storageURL
        } else {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Lemon", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent("history.json")
        }

        if !isPrivate, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    func record(title: String, url: URL) {
        guard !isPrivate else { return }
        entries.removeAll { $0.url == url }
        entries.insert(HistoryEntry(title: title, url: url), at: 0)
        if entries.count > 400 {
            entries = Array(entries.prefix(400))
        }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    func search(_ query: String, limit: Int = 6) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(entries.prefix(limit)) }
        return Array(entries.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(needle)
        }.prefix(limit))
    }

    var grouped: [(String, [HistoryEntry])] {
        grouped(matching: "")
    }

    /// 弹层搜索全部已保存记录，不沿用地址栏建议默认的六条上限。
    func grouped(matching query: String) -> [(String, [HistoryEntry])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        var groups: [(String, [HistoryEntry])] = []
        var bucket: [String: [HistoryEntry]] = [:]
        var order: [String] = []

        for entry in search(query, limit: entries.count) {
            let key: String
            if calendar.isDateInToday(entry.visitedAt) {
                key = "今天"
            } else if calendar.isDateInYesterday(entry.visitedAt) {
                key = "昨天"
            } else {
                key = formatter.string(from: entry.visitedAt)
            }
            if bucket[key] == nil {
                order.append(key)
                bucket[key] = []
            }
            bucket[key]?.append(entry)
        }

        for key in order {
            groups.append((key, bucket[key] ?? []))
        }
        return groups
    }

    private func persist() {
        guard !isPrivate else { return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
