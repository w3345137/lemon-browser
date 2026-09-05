import AppKit
import SwiftUI
import WebKit

// 独立编译 WebKitFactory.swift 时提供它依赖的最小宿主。
enum SafariIdentity {
    static let applicationName = "LemonStackTest"
}

enum CredentialBridge {
    static let captureScript = WKUserScript(
        source: "",
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )
}

final class ContentBlocker {
    static let shared = ContentBlocker()
    func install(on configuration: WKWebViewConfiguration) {}
}

@main
enum TestWebViewStack {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        for isPrivate in [false, true] {
            let view = WebKitFactory.makeWebView(isPrivate: isPrivate)
            precondition(!view.allowsBackForwardNavigationGestures)
            precondition(view.allowsMagnification)
        }
        let container = WebViewStackContainer(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let firstID = UUID()
        let secondID = UUID()
        let first = WKWebView(frame: .zero)
        let second = WKWebView(frame: .zero)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        let addressField = NSTextField(frame: NSRect(x: 20, y: 605, width: 400, height: 24))
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.addSubview(container)
        root.addSubview(addressField)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        container.sync(
            entries: [
                WebViewStackEntry(id: firstID, webView: first),
                WebViewStackEntry(id: secondID, webView: second)
            ],
            selectedID: firstID
        )
        precondition(first.superview === container)
        precondition(second.superview === container)
        precondition(!first.isHidden)
        precondition(second.isHidden)
        let firstParent = first.superview
        let secondParent = second.superview

        container.sync(
            entries: [
                WebViewStackEntry(id: firstID, webView: first),
                WebViewStackEntry(id: secondID, webView: second)
            ],
            selectedID: secondID
        )
        precondition(first.superview === firstParent)
        precondition(second.superview === secondParent)
        precondition(first.isHidden)
        precondition(!second.isHidden)

        // 仅切换可见页时，页签/地址栏可以继续持有焦点；显式 focus token
        // 到达后，目标 WKWebView 必须成为窗口的 first responder。
        window.makeFirstResponder(addressField)
        precondition(window.firstResponder === addressField.currentEditor() || window.firstResponder === addressField)
        let focusRequest = UUID()
        container.sync(
            entries: [
                WebViewStackEntry(id: firstID, webView: first),
                WebViewStackEntry(id: secondID, webView: second)
            ],
            selectedID: secondID,
            focusRequestID: focusRequest
        )
        precondition(waitFor(1) {
            guard let responderView = window.firstResponder as? NSView else { return false }
            return responderView === second || responderView.isDescendant(of: second)
        }, "selected WKWebView never received keyboard focus")

        container.sync(
            entries: [WebViewStackEntry(id: secondID, webView: second)],
            selectedID: secondID
        )
        precondition(first.superview == nil)
        precondition(second.superview === container)
        print("webview-stack-tests=passed")
    }

    private static func waitFor(_ seconds: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
