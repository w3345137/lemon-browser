import AppKit
import Foundation
import WebKit

// 真实 WKWebView + 真实 MediaAudibilityBridge 的端到端可闻性测试：
// 有声 autoplay 页面必须点亮喇叭；静音 autoplay 页面必须保持无图标。
// 夹具在 artifacts/qa-build50/，不存在时按页面内容内联重建到临时目录。
@main
enum TestMediaAudibilityLive {
    @MainActor
    static func main() {
        _ = NSApplication.shared

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemon-media-fixtures-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        // 1 秒 440Hz 正弦波，够触发 audibility 事件即可。
        let sampleRate = 8000
        var wav = Data()
        let dataSize = UInt32(sampleRate * 2)
        wav.append(contentsOf: "RIFF".utf8); wav.append(contentsOf: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian, Array.init))
        wav.append(contentsOf: "WAVEfmt ".utf8); wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian, Array.init))
        wav.append(contentsOf: "data".utf8); wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
        for i in 0..<sampleRate {
            let v = Int16(6000 * sin(2 * Double.pi * 440 * Double(i) / Double(sampleRate)))
            wav.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init))
        }
        let toneURL = fixtureRoot.appendingPathComponent("tone.wav")
        try! wav.write(to: toneURL)

        let audibleURL = fixtureRoot.appendingPathComponent("audible.html")
        try! """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>audible</title></head>
        <body><audio autoplay loop src="tone.wav"></audio></body></html>
        """.write(to: audibleURL, atomically: true, encoding: .utf8)
        let mutedURL = fixtureRoot.appendingPathComponent("muted.html")
        try! """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>muted</title></head>
        <body><audio autoplay loop muted src="tone.wav"></audio></body></html>
        """.write(to: mutedURL, atomically: true, encoding: .utf8)

        // 有声页面：媒体事件桥必须把标签置为 playing。
        // 注意：WKWebView 不挂进可见窗口时页面被视为 hidden，WebKit 不加载
        // 媒体数据（readyState 恒为 0），所以测试必须把 WebView 装进真实窗口。
        do {
            let tab = BrowserTab(isPrivate: false, startURL: audibleURL, loadsImmediately: false)
            tab.windowState = BrowserWindowState()
            tab.activate()
            let host = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            host.title = "Lemon 媒体测试"
            if let webView = tab.webView {
                host.contentView = webView
            }
            host.orderFront(nil)
            defer { host.orderOut(nil); host.contentView = nil }
            precondition(waitFor(8) { tab.mediaState == .playing }, "audible page never reported playing")

            // 点击喇叭图标（toggleAudioMute）后：页面侧强制静音，桥回落为 none，
            // 但媒体仍在播放（progress 不停）——对齐 Chromium 标签静音语义。
            tab.toggleAudioMute()
            precondition(tab.isAudioMuted)
            precondition(waitFor(4) { tab.mediaState == .none }, "muted tab must stop reporting audible")
            var stillPlaying: Any?
            tab.webView?.evaluateJavaScript(
                "(() => { const a = document.querySelector('audio'); return !a.paused && !a.ended; })()",
                in: nil, in: .page
            ) { result in if case .success(let v) = result { stillPlaying = v } }
            precondition(waitFor(4) { stillPlaying != nil })
            precondition(stillPlaying as? Bool == true, "tab mute must not pause the media element")
            // 页面自己的 muted 状态不受标签静音污染（Chromium 同样分离两者）。
            var pageMuted: Any?
            tab.webView?.evaluateJavaScript(
                "document.querySelector('audio').muted",
                in: nil, in: .page
            ) { result in if case .success(let v) = result { pageMuted = v } }
            precondition(waitFor(4) { pageMuted != nil })
            precondition(pageMuted as? Bool == false, "page-visible muted must stay false under tab mute")
            // 实际生效的 muted（隔离世界看到的是真实 DOM 值）必须为 true。
            var domMuted: Any?
            tab.webView?.evaluateJavaScript(
                "document.querySelector('audio').muted",
                in: nil, in: .defaultClient
            ) { result in if case .success(let v) = result { domMuted = v } }
            precondition(waitFor(4) { domMuted != nil })
            precondition(domMuted as? Bool == true, "effective muted must be forced true under tab mute")

            // 再点一次恢复：可闻状态回升为 playing。
            tab.toggleAudioMute()
            precondition(tab.isAudioMuted == false)
            precondition(waitFor(4) { tab.mediaState == .playing }, "unmuted tab must report audible again")
            tab.tearDown()
        }

        // 静音页面：媒体在播放但不可闻，不得出现喇叭（对齐 Chromium 语义）。
        do {
            let tab = BrowserTab(isPrivate: false, startURL: mutedURL, loadsImmediately: false)
            tab.windowState = BrowserWindowState()
            tab.activate()
            let host = NSWindow(
                contentRect: NSRect(x: 560, y: 200, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            host.title = "Lemon 静音媒体测试"
            if let webView = tab.webView {
                host.contentView = webView
            }
            host.orderFront(nil)
            defer { host.orderOut(nil); host.contentView = nil }
            _ = waitFor(4) { tab.mediaState == .playing }
            precondition(tab.mediaState == .none, "muted page must not report playing")
            tab.tearDown()
        }

        // 假可闻自愈：SPA 式清理（innerHTML 直接抹掉播放器，不发 pause 事件）
        // 之后喇叭必须在一轮巡检（2 秒）内熄灭。
        let staleURL = fixtureRoot.appendingPathComponent("stale.html")
        try! """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>stale</title></head>
        <body><audio autoplay loop src="tone.wav"></audio>
        <script>setTimeout(() => { document.body.innerHTML = '<p>gone</p>'; }, 600);</script>
        </body></html>
        """.write(to: staleURL, atomically: true, encoding: .utf8)
        do {
            let tab = BrowserTab(isPrivate: false, startURL: staleURL, loadsImmediately: false)
            tab.windowState = BrowserWindowState()
            tab.activate()
            let host = NSWindow(
                contentRect: NSRect(x: 920, y: 200, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            host.title = "Lemon 假可闻自愈测试"
            if let webView = tab.webView {
                host.contentView = webView
            }
            host.orderFront(nil)
            defer { host.orderOut(nil); host.contentView = nil }
            precondition(waitFor(8) { tab.mediaState == .playing }, "stale fixture never reported playing")
            // innerHTML 清除发生在 0.6s；之后元素事件不再经过 document，
            // 依赖 2 秒巡检自愈。
            precondition(waitFor(6) { tab.mediaState == .none }, "stale audible state must self-heal")
            tab.tearDown()
        }

        print("media-audibility-live-tests=passed")
    }
}
