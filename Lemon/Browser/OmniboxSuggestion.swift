import Foundation

enum OmniboxSuggestionKind: Equatable {
    case openTab
    case bookmark
    case history
    case navigate
    case search

    var title: String {
        switch self {
        case .openTab: "切换到标签"
        case .bookmark: "书签"
        case .history: "历史记录"
        case .navigate: "打开网址"
        case .search: "必应搜索"
        }
    }

    var symbol: String {
        switch self {
        case .openTab: "rectangle.on.rectangle"
        case .bookmark: "star.fill"
        case .history: "clock.arrow.circlepath"
        case .navigate: "globe"
        case .search: "magnifyingglass"
        }
    }
}
