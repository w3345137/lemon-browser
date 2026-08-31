import Foundation

struct ChromiumBookmarks: Decodable {
    struct Roots: Decodable {
        let bookmarkBar: Node
        enum CodingKeys: String, CodingKey { case bookmarkBar = "bookmark_bar" }
    }
    struct Node: Decodable {
        let children: [Node]?
        let name: String
        let type: String
        let url: String?
    }
    let roots: Roots
}

struct LemonBookmark: Codable {
    let id: UUID
    var title: String
    var url: URL
    var isFolder: Bool
    var children: [LemonBookmark]
}

struct LemonSnapshot: Codable {
    var barItems: [LemonBookmark]
    var favorites: [LemonBookmark]
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: ClearUnnamed360BookmarkTitles.swift <360 Bookmarks> <Lemon bookmarks.json>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destinationURL = URL(fileURLWithPath: CommandLine.arguments[2])
let decoder = JSONDecoder()
let source = try decoder.decode(ChromiumBookmarks.self, from: Data(contentsOf: sourceURL))
var snapshot = try decoder.decode(LemonSnapshot.self, from: Data(contentsOf: destinationURL))

func unnamedURLs(in node: ChromiumBookmarks.Node) -> Set<URL> {
    var result = Set<URL>()
    if node.type == "url", node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let urlString = node.url, let url = URL(string: urlString) {
        result.insert(url)
    }
    for child in node.children ?? [] {
        result.formUnion(unnamedURLs(in: child))
    }
    return result
}

let urls = unnamedURLs(in: source.roots.bookmarkBar)
var updated = 0

func clearTitles(in items: inout [LemonBookmark]) {
    for index in items.indices {
        if urls.contains(items[index].url), !items[index].isFolder, !items[index].title.isEmpty {
            items[index].title = ""
            updated += 1
        }
        clearTitles(in: &items[index].children)
    }
}

clearTitles(in: &snapshot.barItems)
guard updated > 0 else {
    print("updated=0")
    exit(0)
}

let formatter = DateFormatter()
formatter.dateFormat = "yyyyMMdd-HHmmss"
let backupURL = destinationURL.deletingPathExtension()
    .appendingPathExtension("before-empty-title-fix-" + formatter.string(from: Date()) + ".json")
try FileManager.default.copyItem(at: destinationURL, to: backupURL)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(snapshot).write(to: destinationURL, options: .atomic)
print("updated=\(updated)")
print("backup=\(backupURL.path)")
