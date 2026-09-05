import AppKit
import WebKit

/// Keep private WebKit SPI in one boundary; never route inspection to another app.
@MainActor
enum InspectorController {
    static func configure(_ view: WKWebView) {
        if #available(macOS 13.3, *) { view.isInspectable = false }
        let preferences = view.configuration.preferences
        let setter = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        guard preferences.responds(to: setter), let implementation = preferences.method(for: setter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(implementation, to: Setter.self)(preferences, setter, true)
    }

    @discardableResult
    static func invoke(_ action: String, on view: WKWebView?) -> Bool {
        guard let view else { return false }
        configure(view)
        let getter = NSSelectorFromString("_inspector")
        let selector = NSSelectorFromString(action)
        guard view.responds(to: getter),
              let inspector = view.perform(getter)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: selector) else { return false }
        inspector.perform(selector)
        return true
    }

    static func open(_ view: WKWebView?, console: Bool = false) {
        guard !invoke(console ? "showConsole" : "show", on: view) else { return }
        let alert = NSAlert()
        alert.messageText = "无法打开开发者工具"
        alert.informativeText = "当前页面尚未加载，或此 macOS 版本不支持应用内检查器。请加载页面后重试。"
        alert.runModal()
    }
}
