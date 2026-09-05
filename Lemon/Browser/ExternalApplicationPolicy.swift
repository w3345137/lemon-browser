import Foundation
import WebKit

/// WKWebView 不会像 Safari 那样自动把网页中的自定义协议交给
/// LaunchServices。Lemon 在导航代理中识别这些请求，并且只在真实
/// 用户操作后允许尝试打开外部 App。
enum ExternalApplicationPolicy {
    static let gestureValidityInterval: TimeInterval = 3

    /// 这些协议应留在 WebKit 内部处理。其他有 scheme 的 URL
    /// 才是候选外部应用链接。
    private static let webKitSchemes: Set<String> = [
        "http", "https", "file", "about", "data", "blob", "javascript"
    ]

    static func externalScheme(for url: URL?) -> String? {
        guard let rawScheme = url?.scheme?.lowercased(),
              !rawScheme.isEmpty,
              !webKitSchemes.contains(rawScheme)
        else { return nil }
        return rawScheme
    }

    static func isRecentGesture(
        at gestureDate: Date?,
        now: Date = Date(),
        validityInterval: TimeInterval = gestureValidityInterval
    ) -> Bool {
        guard let gestureDate else { return false }
        let age = now.timeIntervalSince(gestureDate)
        return age >= 0 && age <= validityInterval
    }

    /// Chromium 会把真实用户激活产生的单个新窗口视为允许的弹窗。
    /// 页面加载或定时器触发的窗口仍交给站点权限处理。
    static func allowsUserInitiatedPopup(
        navigationType: WKNavigationType,
        gestureDate: Date?,
        now: Date = Date()
    ) -> Bool {
        navigationType == .linkActivated || isRecentGesture(at: gestureDate, now: now)
    }

    /// 注入隔离内容世界，页面脚本无法伪造 `isTrusted` 事件，
    /// 也无法直接调用这个 message handler。
    static let userGestureScript = WKUserScript(
        source: #"""
        (() => {
          if (window.__lemonExternalGestureInstalled) return;
          window.__lemonExternalGestureInstalled = true;
          const report = (event) => {
            if (!event.isTrusted) return;
            try {
              window.webkit.messageHandlers.lemonExternalGesture.postMessage({
                type: event.type,
                href: location.href
              });
            } catch (_) {}
          };
          document.addEventListener('pointerdown', report, true);
          document.addEventListener('keydown', report, true);
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .defaultClient
    )
}
