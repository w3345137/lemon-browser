import SwiftUI
import WebKit

enum WebKitFactory {
    @MainActor
    static func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        configuration.applicationNameForUserAgent = SafariIdentity.applicationName
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let hoverScript = WKUserScript(
            source: """
            document.addEventListener('mouseover', function(event) {
              const link = event.target.closest('a');
              if (link && link.href) {
                window.webkit.messageHandlers.lemonHover.postMessage(link.href);
              }
            }, true);
            document.addEventListener('mouseout', function(event) {
              const link = event.target.closest('a');
              if (link) {
                window.webkit.messageHandlers.lemonHover.postMessage('');
              }
            }, true);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(hoverScript)
        configuration.userContentController.addUserScript(CredentialBridge.captureScript)
        configuration.userContentController.addUserScript(MediaAudibilityBridge.userScript)
        configuration.userContentController.addUserScript(MediaAudibilityBridge.webAudioScript)
        configuration.userContentController.addUserScript(MediaAudibilityBridge.tabMuteScript)
        ContentBlocker.shared.install(on: configuration)
        return configuration
    }

    @MainActor
    static func makeWebView(isPrivate: Bool) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration(isPrivate: isPrivate))
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.allowsLinkPreview = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        return webView
    }
}

struct WebViewStackEntry {
    let id: UUID
    let webView: WKWebView
}

/// 一个窗口只创建一个原生 WebView 宿主。所有已加载标签持续留在这个宿主中，
/// 切换标签只改变可见性，避免反复 remove/addSubview 导致 WebKit 重新布局、
/// 后台页面被节流后恢复，以及元素全屏期间父视图被替换。
struct WebViewStackPane: NSViewRepresentable {
    let entries: [WebViewStackEntry]
    let selectedID: UUID?
    let focusRequestID: UUID?

    func makeNSView(context: Context) -> WebViewStackContainer {
        let container = WebViewStackContainer()
        container.sync(entries: entries, selectedID: selectedID, focusRequestID: focusRequestID)
        return container
    }

    func updateNSView(_ nsView: WebViewStackContainer, context: Context) {
        nsView.sync(entries: entries, selectedID: selectedID, focusRequestID: focusRequestID)
    }
}

final class WebViewStackContainer: NSView {
    private var webViews: [UUID: WKWebView] = [:]
    private var fullscreenObservers: [UUID: NSKeyValueObservation] = [:]
    private var selectedID: UUID?
    private var handledFocusRequestID: UUID?

    func sync(entries: [WebViewStackEntry], selectedID: UUID?, focusRequestID: UUID? = nil) {
        self.selectedID = selectedID
        let desiredIDs = Set(entries.map(\.id))

        for id in Array(webViews.keys) where !desiredIDs.contains(id) {
            removeWebView(id: id)
        }

        for entry in entries {
            if webViews[entry.id] !== entry.webView {
                removeWebView(id: entry.id)
                webViews[entry.id] = entry.webView
                observeFullscreen(of: entry.webView, id: entry.id)
            }
            installIfAvailable(entry.webView, id: entry.id)
        }
        needsLayout = true

        if let focusRequestID, focusRequestID != handledFocusRequestID {
            handledFocusRequestID = focusRequestID
            focusSelectedWebView(requestID: focusRequestID, attemptsRemaining: 2)
        }
    }

    override func layout() {
        super.layout()
        for view in webViews.values where view.superview === self {
            view.frame = bounds
        }
    }

    private func installIfAvailable(_ webView: WKWebView, id: UUID) {
        // WebKit 在元素全屏期间拥有 WKWebView 的父视图。进入和退出动画结束前
        // 都不触碰层级，等 KVO 回到 notInFullscreen 后再恢复到稳定宿主。
        guard webView.fullscreenState == .notInFullscreen else { return }
        if webView.superview !== self {
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            webView.frame = bounds
            addSubview(webView)
        }
        webView.frame = bounds
        webView.isHidden = id != selectedID
    }

    /// NSCollectionView 在点击页签后会继续持有键盘焦点。等 SwiftUI/AppKit
    /// 完成本轮显隐与布局，再把 first responder 交给目标 WKWebView；若窗口
    /// 挂载慢一拍，最多重试两轮主队列，不做固定时间等待。
    private func focusSelectedWebView(requestID: UUID, attemptsRemaining: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.handledFocusRequestID == requestID,
                  let selectedID = self.selectedID,
                  let webView = self.webViews[selectedID] else { return }
            guard webView.superview === self, !webView.isHidden, let window = webView.window else {
                guard attemptsRemaining > 0 else { return }
                self.focusSelectedWebView(
                    requestID: requestID,
                    attemptsRemaining: attemptsRemaining - 1
                )
                return
            }
            window.makeFirstResponder(webView)
        }
    }

    private func observeFullscreen(of webView: WKWebView, id: UUID) {
        fullscreenObservers[id]?.invalidate()
        fullscreenObservers[id] = webView.observe(\.fullscreenState, options: [.new]) { [weak self, weak webView] _, _ in
            DispatchQueue.main.async {
                guard let self, let webView,
                      webView.fullscreenState == .notInFullscreen else { return }
                guard self.webViews[id] === webView else {
                    if webView.superview === self { webView.removeFromSuperview() }
                    return
                }
                self.installIfAvailable(webView, id: id)
            }
        }
    }

    private func removeWebView(id: UUID) {
        fullscreenObservers[id]?.invalidate()
        fullscreenObservers.removeValue(forKey: id)
        guard let webView = webViews.removeValue(forKey: id) else { return }
        // 正在全屏时由 WebKit 管理层级；关闭流程会先退出全屏，回到普通状态后
        // WebKit 自行清理占位视图。这里绝不能从全屏窗口强行拔出 WebView。
        if webView.fullscreenState == .notInFullscreen, webView.superview === self {
            webView.removeFromSuperview()
        }
    }
}
