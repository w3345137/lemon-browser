import Combine
import Foundation
import WebKit

extension Notification.Name {
    static let lemonContentBlockerDidChange = Notification.Name("lemonContentBlockerDidChange")
}

@MainActor
final class ContentBlocker: ObservableObject {
    static let shared = ContentBlocker()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isReady = false
    @Published private(set) var statusText = "正在编译拦截规则…"

    private var compiledList: WKContentRuleList?
    private let defaultsKey = "contentBlocker.enabled.v1"

    private init() {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)
        }
    }

    func prepare() {
        let identifier = ContentBlockerRules.identifier
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { [weak self] list, _ in
            Task { @MainActor in
                if let list {
                    self?.adopt(list, status: "已启用 \(ContentBlockerRules.blockedURLFilters.count) 条拦截规则")
                } else {
                    self?.compile(identifier: identifier)
                }
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        statusText = enabled
            ? "已启用 \(ContentBlockerRules.blockedURLFilters.count) 条拦截规则"
            : "广告拦截已关闭"
        NotificationCenter.default.post(name: .lemonContentBlockerDidChange, object: nil)
    }

    func install(on configuration: WKWebViewConfiguration) {
        guard let compiledList else { return }
        configuration.userContentController.remove(compiledList)
        if isEnabled {
            configuration.userContentController.add(compiledList)
        }
    }

    private func compile(identifier: String) {
        do {
            let json = try ContentBlockerRules.jsonString()
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { [weak self] list, error in
                Task { @MainActor in
                    if let list {
                        self?.adopt(list, status: "已启用 \(ContentBlockerRules.blockedURLFilters.count) 条拦截规则")
                    } else {
                        self?.statusText = error?.localizedDescription ?? "内容拦截规则编译失败。"
                    }
                }
            }
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func adopt(_ list: WKContentRuleList, status: String) {
        compiledList = list
        isReady = true
        statusText = isEnabled ? status : "广告拦截已关闭"
        NotificationCenter.default.post(name: .lemonContentBlockerDidChange, object: nil)
    }
}
