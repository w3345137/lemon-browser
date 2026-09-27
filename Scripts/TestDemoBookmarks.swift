import Foundation

@main
struct TestDemoBookmarks {
    @MainActor
    static func main() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemon-demo-bookmarks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let profileURL = testRoot.appendingPathComponent("bookmarks.json")
        let profile = BookmarkStore(storageURL: profileURL)
        let personalURL = URL(string: "https://personal.example")!
        profile.saveBookmark(title: "Personal", url: personalURL, to: .bar)

        let demo = BookmarkStore(inMemory: true)
        precondition(demo.barItems.isEmpty && demo.favorites.isEmpty)
        precondition(!demo.isFavorite(personalURL))
        let demoURL = URL(string: "https://public.example")!
        demo.saveBookmark(title: "Public", url: demoURL, to: .favorites)
        precondition(demo.isFavorite(demoURL))
        precondition(!profile.isFavorite(demoURL))
        precondition(BookmarkStore(inMemory: true).favorites.isEmpty)

        let reloadedProfile = BookmarkStore(storageURL: profileURL)
        precondition(reloadedProfile.isFavorite(personalURL))
        precondition(!reloadedProfile.isFavorite(demoURL))
        print("demo-bookmark-isolation-tests=passed")
    }
}
