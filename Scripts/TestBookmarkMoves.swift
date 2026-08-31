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

        print("bookmark-move-tests=passed")
    }
}
