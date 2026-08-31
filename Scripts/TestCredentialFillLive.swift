import AppKit
import Foundation
import WebKit

// 真实 WKWebView + 真实 CredentialBridge 的端到端填充测试。
// 依赖 Scripts/Fixtures/LoginFixtureServer.py（run-tests.sh 会自动拉起）：
//   18771 直接登录表单；18771/iframe-parent.html 内嵌 18772 跨源 iframe 登录框。
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

        // 3. 跨源 iframe 填充：主文档没有密码框，必须经 postMessage 扇出到
        //    localhost:18772 的框架，由框架内捕获脚本填充并回执。
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
            precondition(fillResult == true, "cross-origin iframe fill reported failure")
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
