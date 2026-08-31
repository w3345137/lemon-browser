import Foundation

struct BookmarkItem: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var url: URL
    var isFolder: Bool
    var children: [BookmarkItem]

    init(id: UUID = UUID(), title: String, url: URL, isFolder: Bool = false, children: [BookmarkItem] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.isFolder = isFolder
        self.children = children
    }

    static let starterBar: [BookmarkItem] = [
        BookmarkItem(title: "Apple", url: URL(string: "https://www.apple.com")!),
        BookmarkItem(title: "iCloud", url: URL(string: "https://www.icloud.com")!),
        BookmarkItem(title: "Google", url: URL(string: "https://www.google.com")!),
        BookmarkItem(title: "YouTube", url: URL(string: "https://www.youtube.com")!),
        BookmarkItem(title: "维基百科", url: URL(string: "https://zh.wikipedia.org")!),
        BookmarkItem(title: "GitHub", url: URL(string: "https://github.com")!),
        BookmarkItem(title: "Bing", url: URL(string: "https://www.bing.com")!)
    ]
}

@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    @Published var barItems: [BookmarkItem]
    @Published var favorites: [BookmarkItem]

    private let url: URL

    init(storageURL: URL? = nil) {
        if let storageURL {
            url = storageURL
            try? FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } else {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Lumen", isDirectory: true) // Legacy namespace preserves existing profiles.
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent("bookmarks.json")
        }

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            barItems = decoded.barItems
            favorites = decoded.favorites
        } else {
            barItems = BookmarkItem.starterBar
            favorites = BookmarkItem.starterBar
        }
    }

    func toggleFavorite(title: String, url: URL) {
        if let index = favorites.firstIndex(where: { $0.url == url }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(BookmarkItem(title: title, url: url), at: 0)
        }
        persist()
    }

    func isFavorite(_ url: URL?) -> Bool {
        guard let url else { return false }
        return favorites.contains(where: { $0.url == url })
    }

    func addToBar(title: String, url: URL) {
        if !barItems.contains(where: { $0.url == url }) {
            barItems.append(BookmarkItem(title: title, url: url))
            persist()
        }
    }

    func addFolder(named rawTitle: String) {
        _ = addFolder(named: rawTitle, in: nil)
    }

    @discardableResult
    func addFolder(named rawTitle: String, in parentFolderID: BookmarkItem.ID?) -> BookmarkItem.ID? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let folder = BookmarkItem(
            title: title,
            url: URL(string: "about:blank")!,
            isFolder: true
        )
        if let parentFolderID {
            var updatedItems = barItems
            guard insert(folder, in: &updatedItems, folderID: parentFolderID, before: nil) else {
                return nil
            }
            barItems = updatedItems
        } else {
            barItems.append(folder)
        }
        persist()
        return folder.id
    }

    @discardableResult
    func addBookmark(title rawTitle: String, url: URL, to folderID: BookmarkItem.ID?) -> BookmarkItem.ID? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = BookmarkItem(title: title, url: url)
        if let folderID {
            var updatedItems = barItems
            guard insert(bookmark, in: &updatedItems, folderID: folderID, before: nil) else {
                return nil
            }
            barItems = updatedItems
        } else {
            barItems.append(bookmark)
        }
        persist()
        return bookmark.id
    }

    @discardableResult
    func addToFolder(_ folderID: BookmarkItem.ID, title: String, url: URL) -> Bool {
        var updatedItems = barItems
        guard insertBookmark(in: &updatedItems, folderID: folderID, title: title, url: url) else {
            return false
        }
        // 整体回写，确保 @Published 对文件夹子项变化立即发出通知。
        barItems = updatedItems
        persist()
        return true
    }

    func removeFromBar(_ item: BookmarkItem) {
        remove(item.id)
    }

    func update(_ itemID: BookmarkItem.ID, title: String, url: URL?) {
        var updatedItems = barItems
        guard updateBookmark(in: &updatedItems, itemID: itemID, title: title, url: url) else {
            return
        }
        barItems = updatedItems
        persist()
    }

    func remove(_ itemID: BookmarkItem.ID) {
        var updatedItems = barItems
        guard removeBookmark(in: &updatedItems, itemID: itemID) else { return }
        barItems = updatedItems
        persist()
    }

    func item(with itemID: BookmarkItem.ID) -> BookmarkItem? {
        findBookmark(in: barItems, itemID: itemID)
    }

    var allURLItems: [BookmarkItem] {
        flattenURLItems(in: barItems)
    }

    var allItems: [BookmarkItem] {
        flattenItems(in: barItems)
    }

    var allFolders: [BookmarkItem] {
        allItems.filter(\.isFolder)
    }

    func children(of folderID: BookmarkItem.ID?) -> [BookmarkItem] {
        guard let folderID else { return barItems }
        return item(with: folderID)?.children ?? []
    }

    func parentFolderID(of itemID: BookmarkItem.ID) -> BookmarkItem.ID? {
        parentFolderID(of: itemID, in: barItems, parentID: nil)
    }

    func path(for itemID: BookmarkItem.ID) -> [String] {
        path(for: itemID, in: barItems, ancestors: []) ?? []
    }

    @discardableResult
    func move(
        _ itemID: BookmarkItem.ID,
        toFolder folderID: BookmarkItem.ID?,
        before siblingID: BookmarkItem.ID?
    ) -> Bool {
        guard let movingItem = item(with: itemID) else { return false }
        guard siblingID != itemID else { return false }

        if let folderID {
            guard folderID != itemID else { return false }
            guard !contains(itemID: folderID, in: movingItem) else { return false }
        }

        var updatedItems = barItems
        guard let extracted = extractBookmark(from: &updatedItems, itemID: itemID) else {
            return false
        }

        let inserted: Bool
        if let folderID {
            inserted = insert(
                extracted,
                in: &updatedItems,
                folderID: folderID,
                before: siblingID
            )
        } else {
            insert(extracted, in: &updatedItems, before: siblingID)
            inserted = true
        }

        guard inserted else { return false }
        barItems = updatedItems
        persist()
        return true
    }

    private func persist() {
        let snapshot = Snapshot(barItems: barItems, favorites: favorites)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func insertBookmark(
        in items: inout [BookmarkItem],
        folderID: BookmarkItem.ID,
        title: String,
        url: URL
    ) -> Bool {
        for index in items.indices {
            if items[index].id == folderID, items[index].isFolder {
                guard !items[index].children.contains(where: { !$0.isFolder && $0.url == url }) else {
                    return false
                }
                items[index].children.append(BookmarkItem(title: title, url: url))
                return true
            }
            if items[index].isFolder,
               insertBookmark(in: &items[index].children, folderID: folderID, title: title, url: url) {
                return true
            }
        }
        return false
    }

    private func updateBookmark(
        in items: inout [BookmarkItem],
        itemID: BookmarkItem.ID,
        title: String,
        url: URL?
    ) -> Bool {
        for index in items.indices {
            if items[index].id == itemID {
                items[index].title = title
                if !items[index].isFolder, let url {
                    items[index].url = url
                }
                return true
            }
            if items[index].isFolder,
               updateBookmark(in: &items[index].children, itemID: itemID, title: title, url: url) {
                return true
            }
        }
        return false
    }

    private func removeBookmark(in items: inout [BookmarkItem], itemID: BookmarkItem.ID) -> Bool {
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items.remove(at: index)
            return true
        }
        for index in items.indices where items[index].isFolder {
            if removeBookmark(in: &items[index].children, itemID: itemID) {
                return true
            }
        }
        return false
    }

    private func findBookmark(in items: [BookmarkItem], itemID: BookmarkItem.ID) -> BookmarkItem? {
        for item in items {
            if item.id == itemID { return item }
            if let found = findBookmark(in: item.children, itemID: itemID) {
                return found
            }
        }
        return nil
    }

    private func flattenURLItems(in items: [BookmarkItem]) -> [BookmarkItem] {
        items.flatMap { item in
            item.isFolder ? flattenURLItems(in: item.children) : [item]
        }
    }

    private func flattenItems(in items: [BookmarkItem]) -> [BookmarkItem] {
        items.flatMap { [$0] + flattenItems(in: $0.children) }
    }

    private func parentFolderID(
        of itemID: BookmarkItem.ID,
        in items: [BookmarkItem],
        parentID: BookmarkItem.ID?
    ) -> BookmarkItem.ID? {
        for item in items {
            if item.id == itemID { return parentID }
            if let found = parentFolderID(of: itemID, in: item.children, parentID: item.id) {
                return found
            }
        }
        return nil
    }

    private func path(
        for itemID: BookmarkItem.ID,
        in items: [BookmarkItem],
        ancestors: [String]
    ) -> [String]? {
        for item in items {
            if item.id == itemID { return ancestors }
            if let found = path(for: itemID, in: item.children, ancestors: ancestors + [item.title]) {
                return found
            }
        }
        return nil
    }

    private func contains(itemID: BookmarkItem.ID, in item: BookmarkItem) -> Bool {
        item.children.contains { child in
            child.id == itemID || contains(itemID: itemID, in: child)
        }
    }

    private func extractBookmark(
        from items: inout [BookmarkItem],
        itemID: BookmarkItem.ID
    ) -> BookmarkItem? {
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            return items.remove(at: index)
        }
        for index in items.indices where items[index].isFolder {
            if let extracted = extractBookmark(from: &items[index].children, itemID: itemID) {
                return extracted
            }
        }
        return nil
    }

    private func insert(
        _ item: BookmarkItem,
        in items: inout [BookmarkItem],
        before siblingID: BookmarkItem.ID?
    ) {
        if let siblingID, let index = items.firstIndex(where: { $0.id == siblingID }) {
            items.insert(item, at: index)
        } else {
            items.append(item)
        }
    }

    private func insert(
        _ item: BookmarkItem,
        in items: inout [BookmarkItem],
        folderID: BookmarkItem.ID,
        before siblingID: BookmarkItem.ID?
    ) -> Bool {
        for index in items.indices {
            if items[index].id == folderID, items[index].isFolder {
                insert(item, in: &items[index].children, before: siblingID)
                return true
            }
            if items[index].isFolder,
               insert(item, in: &items[index].children, folderID: folderID, before: siblingID) {
                return true
            }
        }
        return false
    }

    private struct Snapshot: Codable {
        var barItems: [BookmarkItem]
        var favorites: [BookmarkItem]
    }
}
