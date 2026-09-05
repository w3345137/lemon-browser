import Foundation

@main
struct TestBookmarkMoves {
    @MainActor
    static func main() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemon-bookmark-move-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let store = BookmarkStore(storageURL: testRoot.appendingPathComponent("bookmarks.json"))
        let first = BookmarkItem(title: "First", url: URL(string: "https://first.example")!)
        let second = BookmarkItem(title: "Second", url: URL(string: "https://second.example")!)
        let childFolder = BookmarkItem(
            title: "Child",
            url: URL(string: "about:blank")!,
            isFolder: true
        )
        let folder = BookmarkItem(
            title: "Folder",
            url: URL(string: "about:blank")!,
            isFolder: true,
            children: [childFolder]
        )
        store.barItems = [first, second, folder]

        precondition(store.move(second.id, toFolder: nil, before: first.id))
        precondition(store.barItems.map(\.id).prefix(2) == [second.id, first.id])

        precondition(store.move(first.id, toFolder: folder.id, before: childFolder.id))
        precondition(store.item(with: folder.id)?.children.map(\.id) == [first.id, childFolder.id])

        precondition(!store.move(folder.id, toFolder: childFolder.id, before: nil))
        precondition(store.barItems.contains(where: { $0.id == folder.id }))

        precondition(store.move(first.id, toFolder: nil, before: nil))
        precondition(store.barItems.last?.id == first.id)

        let nestedFolderID = store.addFolder(named: "Nested", in: folder.id)
        precondition(nestedFolderID != nil)
        let addedBookmarkID = store.addBookmark(
            title: "Added",
            url: URL(string: "https://added.example")!,
            to: nestedFolderID
        )
        precondition(addedBookmarkID != nil)
        precondition(store.parentFolderID(of: addedBookmarkID!) == nestedFolderID)
        precondition(store.path(for: addedBookmarkID!) == ["Folder", "Nested"])
        precondition(store.children(of: nestedFolderID).map(\.id) == [addedBookmarkID!])

        // Move a folder containing a bookmark between nested folders, then
        // back onto the bar. The subtree and persisted order must survive.
        precondition(store.move(nestedFolderID!, toFolder: childFolder.id, before: nil))
        precondition(store.path(for: addedBookmarkID!) == ["Folder", "Child", "Nested"])
        precondition(!store.move(childFolder.id, toFolder: nestedFolderID!, before: nil))
        precondition(!store.move(nestedFolderID!, toFolder: nestedFolderID!, before: nil))
        precondition(store.move(nestedFolderID!, toFolder: nil, before: folder.id))
        precondition(store.children(of: nestedFolderID).map(\.id) == [addedBookmarkID!])
        let restored = BookmarkStore(storageURL: testRoot.appendingPathComponent("bookmarks.json"))
        precondition(restored.barItems.map(\.id) == store.barItems.map(\.id))
        precondition(restored.children(of: nestedFolderID).map(\.id) == [addedBookmarkID!])

        let savedURL = URL(string: "https://saved.example/article")!
        store.saveBookmark(title: "Saved", url: savedURL, to: .favorites)
        precondition(store.bookmarkDestination(for: savedURL) == .favorites)
        precondition(store.savedTitle(for: savedURL) == "Saved")

        store.saveBookmark(title: "Saved in bar", url: savedURL, to: .bar)
        precondition(store.bookmarkDestination(for: savedURL) == .bar)
        precondition(store.favorites.contains(where: { $0.url == savedURL }) == false)
        precondition(store.allURLItems.filter { $0.url == savedURL }.count == 1)

        store.saveBookmark(title: "Saved in folder", url: savedURL, to: .folder(folder.id))
        precondition(store.bookmarkDestination(for: savedURL) == .folder(folder.id))
        precondition(store.savedTitle(for: savedURL) == "Saved in folder")
        precondition(store.allURLItems.filter { $0.url == savedURL }.count == 1)

        store.removeSavedBookmark(for: savedURL)
        precondition(store.bookmarkDestination(for: savedURL) == nil)

        print("bookmark-move-tests=passed")
    }
}
