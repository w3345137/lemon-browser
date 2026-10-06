import Foundation
import Combine

@main
struct TestHistorySearch {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemon-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("history.json")
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let entries = (0..<10).map { index in
            HistoryEntry(title: "中文搜索 Page \(index)",
                         url: URL(string: "https://example.com/History/\(index)")!,
                         visitedAt: index < 7 ? now : yesterday)
        } + [HistoryEntry(title: "Another page", url: URL(string: "https://other.example.org")!)]
        try JSONEncoder().encode(entries).write(to: storage)
        let history = HistoryStore(isPrivate: false, storageURL: storage)
        func count(_ query: String) -> Int {
            history.grouped(matching: query).reduce(0) { $0 + $1.1.count }
        }
        precondition(count("中文搜索") == 10, "Search must not stop at six results")
        precondition(count("  PAGE  ") == 11, "Trim and ignore case")
        precondition(count("example.com/history/") == 10, "Search full URL")
        precondition(count("not found") == 0)
        precondition(count(" \n ") == entries.count, "Clearing search restores all records")
        let groups = history.grouped(matching: "中文搜索")
        precondition(groups.map(\.0) == ["今天", "昨天"])
        precondition(groups.flatMap(\.1).map(\.id) == Array(entries.prefix(10)).map(\.id))
        precondition(history.search("中文搜索").count == 6, "Preserve omnibox result limit")
        history.record(title: "中文搜索 Added", url: URL(string: "https://example.com/new")!)
        precondition(count("中文搜索") == 11, "Search tracks new entries")
        history.clear()
        precondition(count("") == 0 && count("中文搜索") == 0)
        let privateHistory = HistoryStore(isPrivate: true, storageURL: storage)
        privateHistory.record(title: "Private", url: URL(string: "https://example.com/private")!)
        precondition(privateHistory.grouped(matching: "Private").isEmpty)
        print("history-search-tests=passed")
    }
}
