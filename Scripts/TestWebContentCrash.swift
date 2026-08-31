import AppKit
import SwiftUI
import WebKit

@main
enum TestWebContentCrash {
    @MainActor
    static func main() {
        _ = NSApplication.shared

        let url = URL(string: "https://example.com/")!
        let tab = BrowserTab(isPrivate: false, startURL: url, loadsImmediately: false)
        let webView = tab.ensureWebView()
        precondition(!tab.webContentDidCrash)

        // 其他 WebView 的进程退出不能误标本标签。
        let unrelatedWebView = WKWebView(frame: .zero)
        tab.webViewWebContentProcessDidTerminate(unrelatedWebView)
        precondition(!tab.webContentDidCrash)

        // 自己的 WebContent 崩溃：标记崩溃、停止加载指示、清除媒体状态。
        tab.webViewWebContentProcessDidTerminate(webView)
        precondition(tab.webContentDidCrash)
        precondition(!tab.isLoading)
        precondition(tab.estimatedProgress == 0)
        precondition(tab.mediaState == .none)

        // 重新载入（崩溃占位按钮与 ⌘R 共用此路径）清除崩溃标记。
        tab.reload()
        precondition(!tab.webContentDidCrash)

        // 再次崩溃后 tearDown 进入已释放状态，之后的进程退出不再误标。
        tab.webViewWebContentProcessDidTerminate(webView)
        precondition(tab.webContentDidCrash)
        tab.tearDown()
        precondition(tab.webView == nil)
        precondition(!tab.webContentDidCrash)
        tab.webViewWebContentProcessDidTerminate(webView)
        precondition(!tab.webContentDidCrash)

        print("webcontent-crash-tests=passed")
    }
}
