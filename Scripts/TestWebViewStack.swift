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

final class FocusProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
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

        // Native key events must reach the DOM, not merely an AppKit responder.
        second.loadHTMLString("<html><body><script>window.keys=[];addEventListener('keydown',e=>{keys.push(e.key);e.preventDefault()});</script>Keyboard fixture</body></html>", baseURL: nil)
        var ready = false
        precondition(waitFor(5) {
            second.evaluateJavaScript("Array.isArray(window.keys)") { value, _ in ready = value as? Bool == true }
            return ready
        })
        for (code, chars) in [(UInt16(49), " "), (UInt16(123), "\u{F702}"), (UInt16(124), "\u{F703}")] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
        }
        var keys: [String] = []
        precondition(waitFor(5) {
            second.evaluateJavaScript("window.keys") { value, _ in keys = value as? [String] ?? [] }
            return keys == [" ", "ArrowLeft", "ArrowRight"]
        }, "native space/arrow events did not reach DOM: \(keys)")

        let probe = FocusProbe(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        second.addSubview(probe)
        precondition(window.makeFirstResponder(probe))
        let entries = [WebViewStackEntry(id: firstID, webView: first),
                       WebViewStackEntry(id: secondID, webView: second)]
        container.sync(entries: entries, selectedID: firstID, focusRequestID: UUID())
        precondition(waitFor(1) { window.firstResponder === first })
        container.sync(entries: entries, selectedID: secondID, focusRequestID: UUID())
        precondition(waitFor(1) { window.firstResponder === probe }, "internal responder was not restored")
        probe.removeFromSuperview()
        window.makeFirstResponder(addressField)
        container.sync(entries: entries, selectedID: secondID, focusRequestID: UUID())
        precondition(waitFor(1) { window.firstResponder === second }, "detached responder did not fall back")

        // 窗口重新成为 key（⌘Tab 回浏览器、点 Dock 图标、点 chrome 激活）时：
        // 焦点在 chrome 非文本控件上 → 必须还给选中页的 WKWebView，
        // 否则空格等按键到不了页面，视频空格暂停失效。
        let chromeProbe = FocusProbe(frame: NSRect(x: 0, y: 610, width: 10, height: 10))
        root.addSubview(chromeProbe)
        precondition(window.makeFirstResponder(chromeProbe))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        precondition(waitFor(1) { window.firstResponder === second },
            "window-key activation did not return focus to the selected page")

        // 页面已持有焦点时重激活：不得重置 WebKit 内部 responder / DOM 焦点。
        second.addSubview(probe)
        precondition(window.makeFirstResponder(probe))
        container.sync(entries: entries, selectedID: secondID)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        precondition(window.firstResponder === probe, "page focus was reset on window activation")

        // WebKit 内部 responder 已被记住时，重激活要恢复它（保住 focused frame），
        // 而不是退化成 WKWebView 本身。
        precondition(window.makeFirstResponder(chromeProbe))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        precondition(waitFor(1) { window.firstResponder === probe },
            "window-key activation did not restore the saved internal responder")

        // 地址栏/查找栏等文本编辑持有焦点时（field editor 或 NSTextField），
        // 重激活不抢焦点。
        precondition(window.makeFirstResponder(addressField))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let editingResponder = window.firstResponder
        precondition(editingResponder === addressField || editingResponder === addressField.currentEditor(),
            "text editing focus was stolen on window activation")
        probe.removeFromSuperview()

        // 检查器已迁移到公开 API（isInspectable），不再随标签切换管理检查器窗口。
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
