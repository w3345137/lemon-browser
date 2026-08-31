import Foundation

struct ChromiumBookmarks: Decodable {
    struct Roots: Decodable {
        let bookmarkBar: Node

        enum CodingKeys: String, CodingKey {
            case bookmarkBar = "bookmark_bar"
        }
    }

    struct Node: Decodable {
        let children: [Node]?
        let guid: String?
        let name: String
        let type: String
        let url: String?
    }

    let roots: Roots
}

struct LemonBookmark: Codable {
    let id: UUID
    let title: String
    let url: URL
    let isFolder: Bool
    let children: [LemonBookmark]
}

struct LemonSnapshot: Codable {
    var barItems: [LemonBookmark]
    var favorites: [LemonBookmark]
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: Import360Bookmarks.swift <360 Bookmarks> <Lemon bookmarks.json>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destinationURL = URL(fileURLWithPath: CommandLine.arguments[2])
let decoder = JSONDecoder()
let source = try decoder.decode(ChromiumBookmarks.self, from: Data(contentsOf: sourceURL))

func convert(_ node: ChromiumBookmarks.Node) -> LemonBookmark? {
    let id = node.guid.flatMap(UUID.init(uuidString:)) ?? UUID()
    if node.type == "folder" {
        return LemonBookmark(
            id: id,
            title: node.name.isEmpty ? "未命名文件夹" : node.name,
            url: URL(string: "about:blank")!,
            isFolder: true,
            children: (node.children ?? []).compactMap(convert)
        )
    }

    guard node.type == "url", let rawURL = node.url, let url = URL(string: rawURL) else {
        return nil
    }
    return LemonBookmark(
        id: id,
        title: node.name,
        url: url,
        isFolder: false,
        children: []
    )
}

let importedBar = (source.roots.bookmarkBar.children ?? []).compactMap(convert)
let existing: LemonSnapshot
if let data = try? Data(contentsOf: destinationURL),
   let snapshot = try? decoder.decode(LemonSnapshot.self, from: data) {
    existing = snapshot
} else {
    existing = LemonSnapshot(barItems: [], favorites: [])
}

try FileManager.default.createDirectory(
    at: destinationURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

if FileManager.default.fileExists(atPath: destinationURL.path) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let backupURL = destinationURL.deletingPathExtension()
        .appendingPathExtension("before-360-" + formatter.string(from: Date()) + ".json")
    try FileManager.default.copyItem(at: destinationURL, to: backupURL)
    print("backup=" + backupURL.path)
}

let output = LemonSnapshot(barItems: importedBar, favorites: existing.favorites)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(output).write(to: destinationURL, options: .atomic)

func countNodes(_ items: [LemonBookmark]) -> Int {
    items.reduce(0) { $0 + 1 + countNodes($1.children) }
}

print("top_level=" + String(importedBar.count))
print("total=" + String(countNodes(importedBar)))
print("destination=" + destinationURL.path)
