import Foundation

@main
struct TestOmniboxRanker {
    static func main() {
        let now = Date()
        let tabID = UUID()
        let candidates = [
            OmniboxCandidate(
                id: "tab",
                kind: .openTab,
                title: "小红书",
                subtitle: "https://www.xiaohongshu.com",
                url: URL(string: "https://www.xiaohongshu.com")!,
                tabID: tabID
            ),
            OmniboxCandidate(
                id: "bookmark",
                kind: .bookmark,
                title: "小红书首页",
                subtitle: "https://www.xiaohongshu.com",
                url: URL(string: "https://www.xiaohongshu.com")!
            ),
            OmniboxCandidate(
                id: "history-old",
                kind: .history,
                title: "包含小红书的文章",
                subtitle: "https://example.com/post",
                url: URL(string: "https://example.com/post")!,
                visitedAt: now.addingTimeInterval(-200_000)
            ),
            OmniboxCandidate(
                id: "history-recent",
                kind: .history,
                title: "GitHub",
                subtitle: "https://github.com",
                url: URL(string: "https://github.com")!,
                visitedAt: now.addingTimeInterval(-60)
            ),
            OmniboxCandidate(
                id: "navigate",
                kind: .navigate,
                title: "github.com",
                subtitle: "https://github.com",
                url: URL(string: "https://github.com")!
            ),
            OmniboxCandidate(
                id: "search",
                kind: .search,
                title: "使用必应搜索“github.com”",
                subtitle: "https://www.bing.com/search?q=github.com",
                url: URL(string: "https://www.bing.com/search?q=github.com")!
            )
        ]

        let xhs = OmniboxRanker.ranked(candidates, query: "小红")
        precondition(xhs.first?.kind == .openTab)
        precondition(xhs.contains { $0.kind == .bookmark } == false || xhs.first?.kind == .openTab)

        let github = OmniboxRanker.ranked(candidates, query: "github.com")
        precondition(github.contains { $0.kind == .navigate })
        precondition((github.first { $0.kind == .navigate }).map {
            OmniboxRanker.score(query: "github.com", candidate: $0)
        } ?? 0 > (github.first { $0.kind == .search }).map {
            OmniboxRanker.score(query: "github.com", candidate: $0)
        } ?? 0)

        let searchQuery = OmniboxCandidate(
            id: "search-plain",
            kind: .search,
            title: "使用必应搜索“开源浏览器”",
            subtitle: "https://www.bing.com/search?q=%E5%BC%80%E6%BA%90%E6%B5%8F%E8%A7%88%E5%99%A8",
            url: URL(string: "https://www.bing.com/search?q=open-source-browser")!
        )
        let navigatePlain = OmniboxCandidate(
            id: "navigate-plain",
            kind: .navigate,
            title: "开源浏览器",
            subtitle: "https://www.bing.com/search?q=open-source-browser",
            url: URL(string: "https://www.bing.com/search?q=open-source-browser")!
        )
        precondition(
            OmniboxRanker.score(query: "开源浏览器", candidate: searchQuery)
                > OmniboxRanker.score(query: "开源浏览器", candidate: navigatePlain)
        )

        let prefix = OmniboxRanker.matchScore(
            query: "git",
            candidate: OmniboxCandidate(
                id: "gh",
                kind: .bookmark,
                title: "GitHub",
                subtitle: "https://github.com",
                url: URL(string: "https://github.com")!
            )
        )
        let contains = OmniboxRanker.matchScore(
            query: "hub",
            candidate: OmniboxCandidate(
                id: "gh2",
                kind: .bookmark,
                title: "GitHub",
                subtitle: "https://github.com",
                url: URL(string: "https://github.com")!
            )
        )
        precondition(prefix > contains)

        print("omnibox-ranker-tests=passed")
    }
}
