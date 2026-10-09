import Combine
import Foundation

/// 浏览器级交互偏好，不随窗口或网页资料变化；默认保持既有点击行为。
@MainActor
final class TabInteractionPreferences: ObservableObject {
    static let shared = TabInteractionPreferences()
    private let defaults: UserDefaults
    private static let doubleClickKey = "tabInteraction.closeOnDoubleClick"
    private static let rightClickKey = "tabInteraction.closeOnRightClick"

    @Published var closeOnDoubleClick: Bool {
        didSet { defaults.set(closeOnDoubleClick, forKey: Self.doubleClickKey) }
    }
    @Published var closeOnRightClick: Bool {
        didSet { defaults.set(closeOnRightClick, forKey: Self.rightClickKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        closeOnDoubleClick = defaults.bool(forKey: Self.doubleClickKey)
        closeOnRightClick = defaults.bool(forKey: Self.rightClickKey)
    }
}
