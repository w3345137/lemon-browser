import AppKit
import Foundation
import WebKit

@main
enum TestCredentialCapture {
    @MainActor
    static func main() {
        _ = NSApplication.shared

        let pageURL = URL(string: "https://login.example.com/")!
        let otherURL = URL(string: "https://login.example.com/home")!

        // 1. 捕获提交后不能立即弹保存提示（等“登录可能成功”的信号）。
        do {
            let windowState = BrowserWindowState()
            let tab = BrowserTab(isPrivate: false, startURL: pageURL, loadsImmediately: false)
            tab.windowState = windowState
            tab.recordCredentialCapture(scope: "https://login.example.com", username: "u1", password: "p1", pageURL: pageURL)
            precondition(windowState.offeredCredentials.isEmpty)
            tab.tearDown()
        }

        // 2. 提交后导航到新 URL → 视为登录成功，弹出保存提示。
        do {
            let windowState = BrowserWindowState()
            let tab = BrowserTab(isPrivate: false, startURL: pageURL, loadsImmediately: false)
            tab.windowState = windowState
            tab.recordCredentialCapture(scope: "https://login.example.com", username: "u2", password: "p2", pageURL: pageURL)
            tab.handleNavigationFinished(url: otherURL)
            precondition(windowState.offeredCredentials.count == 1)
            precondition(windowState.offeredCredentials.first?.username == "u2")
            tab.tearDown()
        }

        // 3. 提交后同 URL 重载 → 视为登录失败，丢弃，不再提示。
        do {
            let windowState = BrowserWindowState()
            let tab = BrowserTab(isPrivate: false, startURL: pageURL, loadsImmediately: false)
            tab.windowState = windowState
            tab.recordCredentialCapture(scope: "https://login.example.com", username: "u3", password: "p3", pageURL: pageURL)
            tab.handleNavigationFinished(url: pageURL)
            precondition(windowState.offeredCredentials.isEmpty)
            tab.handleURLChange(url: otherURL)
            precondition(windowState.offeredCredentials.isEmpty)
            tab.tearDown()
        }

        // 4. SPA 路由变化（只改 URL、没有导航回调）也要触发提示。
        do {
            let windowState = BrowserWindowState()
            let tab = BrowserTab(isPrivate: false, startURL: pageURL, loadsImmediately: false)
            tab.windowState = windowState
            tab.recordCredentialCapture(scope: "https://login.example.com", username: "u4", password: "p4", pageURL: pageURL)
            tab.handleURLChange(url: pageURL)
            precondition(windowState.offeredCredentials.isEmpty)
            tab.handleURLChange(url: otherURL)
            precondition(windowState.offeredCredentials.count == 1)
            tab.tearDown()
        }

        // 5. 仅经过时间不能证明登录成功，不得弹出保存提示。
        do {
            let windowState = BrowserWindowState()
            let tab = BrowserTab(isPrivate: false, startURL: pageURL, loadsImmediately: false)
            tab.windowState = windowState
            BrowserTab.credentialCaptureConfirmDelay = 0.2
            tab.recordCredentialCapture(scope: "https://login.example.com", username: "u5", password: "p5", pageURL: pageURL)
            precondition(windowState.offeredCredentials.isEmpty)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
            precondition(windowState.offeredCredentials.isEmpty)
            BrowserTab.credentialCaptureConfirmDelay = 6
            tab.tearDown()
        }

        // 6. 去重：同一组凭据提示过一次后，重复捕获不再提示。
        do {
            let windowState = BrowserWindowState()
            let tab = BrowserTab(isPrivate: false, startURL: pageURL, loadsImmediately: false)
            tab.windowState = windowState
            tab.recordCredentialCapture(scope: "https://login.example.com", username: "u6", password: "p6", pageURL: pageURL)
            tab.handleNavigationFinished(url: otherURL)
            precondition(windowState.offeredCredentials.count == 1)
            tab.recordCredentialCapture(scope: "https://login.example.com", username: "u6", password: "p6", pageURL: pageURL)
            tab.handleNavigationFinished(url: pageURL)
            precondition(windowState.offeredCredentials.count == 1)
            tab.tearDown()
        }

        print("credential-capture-tests=passed")
    }
}
