import AppKit
import Foundation
import WebKit

// 真实 WKWebView + 真实 CredentialBridge 的端到端填充测试。
// 依赖 Scripts/Fixtures/LoginFixtureServer.py（run-tests.sh 会自动拉起）：
//   18771 直接登录表单；18771/iframe-parent.html 内嵌 18772 跨源 iframe 登录框。
@MainActor
private func readFrameValues(_ tab: BrowserTab) -> String? {
    var posted = false
    tab.webView?.evaluateJavaScript("""
        window.fixtureValues = null;
        addEventListener('message', event => {
            if (event.origin === 'http://localhost:18772' && typeof event.data.fixtureValues === 'string') window.fixtureValues = event.data.fixtureValues;
        });
        document.querySelector('iframe').contentWindow.postMessage('fixture-read-values', 'http://localhost:18772');
        """) { _, _ in posted = true }
    guard waitFor(2, condition: { posted }) else { return nil }
    var values: String?
    _ = waitFor(2) {
        tab.webView?.evaluateJavaScript("window.fixtureValues") { value, _ in values = value as? String }
        return values != nil
    }
    return values
}

@main
enum TestCredentialFillLive {
    @MainActor
    static func main() {
        _ = NSApplication.shared

        // 服务器不在时明确跳过，避免把环境问题误判为回归失败。
        guard (try? String(contentsOf: URL(string: "http://localhost:18771/login.html")!)) != nil else {
            print("credential-fill-live-tests=skipped (login fixture server not running)")
            return
        }

        let windowState = BrowserWindowState()

        // 1. 主框架直接填充：调度器直填路径，读回 DOM 值验证。
        do {
            let tab = BrowserTab(isPrivate: false, startURL: URL(string: "http://localhost:18771/login.html")!, loadsImmediately: false)
            tab.windowState = windowState
            tab.activate()
            let loadedBefore = windowState.finishedNavigations
            precondition(waitFor(10) { windowState.finishedNavigations > loadedBefore }, "login page did not finish loading")

            var fillResult: Bool?
            tab.fill(WebCredential(scope: "http://localhost:18771", username: "qa-user"), password: "qa-pass") { ok in
                fillResult = ok
            }
            precondition(waitFor(5) { fillResult != nil }, "fill completion never fired")
            precondition(fillResult == true, "direct fill reported failure")

            var values: String?
            tab.webView?.evaluateJavaScript(
                "document.querySelector('input[name=username]').value + '|' + document.querySelector('input[name=password]').value"
            ) { result, _ in
                values = result as? String
            }
            precondition(waitFor(5) { values != nil })
            precondition(values == "qa-user|qa-pass", "unexpected filled values: \(values ?? "nil")")
            tab.tearDown()
        }

        // 2. 仅密码凭据：保留网页中已有账号，只替换密码。
        do {
            let tab = BrowserTab(isPrivate: false, startURL: URL(string: "http://localhost:18771/login.html")!, loadsImmediately: false)
            tab.windowState = windowState
            tab.activate()
            let loadedBefore = windowState.finishedNavigations
            precondition(waitFor(10) { windowState.finishedNavigations > loadedBefore }, "password-only page did not finish loading")

            var seeded = false
            tab.webView?.evaluateJavaScript("document.querySelector('input[name=username]').value = 'existing-user'") { _, _ in
                seeded = true
            }
            precondition(waitFor(5) { seeded })

            var fillResult: Bool?
            tab.fill(WebCredential(scope: "http://localhost:18771", username: ""), password: "password-only-secret") { ok in
                fillResult = ok
            }
            precondition(waitFor(5) { fillResult != nil })
            precondition(fillResult == true, "password-only fill reported failure")

            var values: String?
            tab.webView?.evaluateJavaScript(
                "document.querySelector('input[name=username]').value + '|' + document.querySelector('input[name=password]').value"
            ) { result, _ in
                values = result as? String
            }
            precondition(waitFor(5) { values != nil })
            precondition(values == "existing-user|password-only-secret", "password-only fill cleared username")
            tab.tearDown()
        }

        // 3. Different ports are different origins: do not disclose credentials.
        do {
            let tab = BrowserTab(isPrivate: false, startURL: URL(string: "http://localhost:18771/iframe-parent.html")!, loadsImmediately: false)
            tab.windowState = windowState
            tab.activate()
            let loadedBefore = windowState.finishedNavigations
            precondition(waitFor(10) { windowState.finishedNavigations > loadedBefore }, "iframe parent did not finish loading")
            // iframe 加载与捕获脚本注入略晚于主框架 didFinish。
            _ = waitFor(1) { false }

            var fillResult: Bool?
            tab.fill(WebCredential(scope: "http://localhost:18771", username: "qa-user"), password: "qa-pass") { ok in
                fillResult = ok
            }
            precondition(waitFor(6) { fillResult != nil }, "iframe fill completion never fired")
            precondition(fillResult == false, "cross-origin iframe must not receive credentials")
            var probed = false
            tab.webView?.evaluateJavaScript("""
                window.fixtureEmpty = null;
                addEventListener('message', event => {
                    if (event.origin === 'http://localhost:18772' && typeof event.data.fixtureEmpty === 'boolean') window.fixtureEmpty = event.data.fixtureEmpty;
                });
                document.querySelector('iframe').contentWindow.postMessage('fixture-check-empty', 'http://localhost:18772');
                """) { _, _ in probed = true }
            precondition(waitFor(2) { probed })
            _ = waitFor(0.3) { false }
            var empty: Bool?
            tab.webView?.evaluateJavaScript("window.fixtureEmpty") { value, _ in empty = value as? Bool }
            precondition(waitFor(2) { empty != nil })
            precondition(empty == true, "No secret may reach the cross-origin frame even if the callback says failure")
            tab.tearDown()
        }

        // 3b. 同站内嵌登录框（App Store Connect 内嵌 idmsa.apple.com 的场景）：
        //     凭据按框架源保存，只填进源完全一致的框架，并能在框架里捕获提交。
        do {
            let tab = BrowserTab(isPrivate: false, startURL: URL(string: "http://localhost:18771/iframe-parent.html")!, loadsImmediately: false)
            tab.windowState = windowState
            tab.activate()
            let loadedBefore = windowState.finishedNavigations
            precondition(waitFor(10) { windowState.finishedNavigations > loadedBefore }, "iframe parent did not finish loading")
            precondition(waitFor(5) { tab.credentialScopes.contains("http://localhost:18772") },
                         "same-site login frame was not registered: \(tab.credentialScopes)")
            precondition(tab.credentialScopes.first == "http://localhost:18771", "page scope must stay first")

            var fillResult: Bool?
            tab.fill(WebCredential(scope: "http://localhost:18772", username: "frame-qa"), password: "frame-pass") { ok in
                fillResult = ok
            }
            precondition(waitFor(5) { fillResult != nil }, "frame fill completion never fired")
            precondition(fillResult == true, "same-site frame fill reported failure")
            precondition(readFrameValues(tab) == "frame-qa|frame-pass", "frame fill did not land")

            // 捕获：框架内提交 → 登录框消失 → 按框架源提示保存。
            let previousDelay = BrowserTab.credentialCaptureConfirmDelay
            BrowserTab.credentialCaptureConfirmDelay = 0.5
            defer { BrowserTab.credentialCaptureConfirmDelay = previousDelay }
            let offeredBefore = windowState.offeredCredentials.count
            var posted = false
            tab.webView?.evaluateJavaScript(
                "document.querySelector('iframe').contentWindow.postMessage('fixture-submit', 'http://localhost:18772')"
            ) { _, _ in posted = true }
            precondition(waitFor(2) { posted })
            precondition(waitFor(5) { windowState.offeredCredentials.count > offeredBefore }, "frame login was not offered for saving")
            let offered = windowState.offeredCredentials.last!
            precondition(offered.scope == "http://localhost:18772" && offered.username == "frame-user",
                         "frame credential saved under wrong scope: \(offered)")
            tab.tearDown()
        }

        // 4. 无表单页面：填充应报告失败（触发上层重试/提示），不能静默。
        do {
            let tab = BrowserTab(isPrivate: false, startURL: URL(string: "http://localhost:18771/success")!, loadsImmediately: false)
            tab.windowState = windowState
            tab.activate()
            let loadedBefore = windowState.finishedNavigations
            precondition(waitFor(10) { windowState.finishedNavigations > loadedBefore })

            var fillResult: Bool?
            tab.fill(WebCredential(scope: "http://localhost:18771", username: "qa-user"), password: "qa-pass") { ok in
                fillResult = ok
            }
            precondition(waitFor(6) { fillResult != nil }, "failure completion never fired")
            precondition(fillResult == false, "page without a form must report failure")
            tab.tearDown()
        }

        print("credential-fill-live-tests=passed")
    }
}
