import AppKit
import WebKit

@MainActor
final class CredentialMessages: NSObject, WKScriptMessageHandler {
    var submissions: [[String: Any]] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], body["type"] as? String == "submit" {
            submissions.append(body)
        }
    }
}

@main
struct TestCredentialCodeFields {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let messages = CredentialMessages()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(CredentialBridge.captureScript)
        config.userContentController.add(messages, name: CredentialBridge.handlerName)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let html = """
        <form id="form"><input autocomplete="username" value="fixture-user">
        <label for="code">短信验证码</label><input id="code" type="password" autocomplete="one-time-code" value="123456">
        <button id="send" type="button">获取验证码</button><button id="login" type="button">登录</button></form>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://fixture.example"))
        for _ in 0..<50 {
            if (try? await view.evaluateJavaScript("typeof window.__lemonPerformFill === 'function' && !!document.getElementById('login')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let filled = try await view.evaluateJavaScript("window.__lemonPerformFill('new-user', 'real-password')")
        precondition(filled as? Bool == false, "Do not fill a saved password into an OTP field")
        for code in ["123456", "654321"] {
            _ = try await view.evaluateJavaScript("document.getElementById('code').value='\(code)'; document.getElementById('login').click()")
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        precondition(messages.submissions.isEmpty, "OTP-only login never offers password saving")
        _ = try await view.evaluateJavaScript("""
        const password = document.createElement('input'); password.type='password'; password.autocomplete='current-password';
        password.value='real-password'; document.getElementById('form').append(password);
        document.getElementById('send').click();
        """)
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(messages.submissions.isEmpty, "Sending a verification code is not a login submission")
        _ = try await view.evaluateJavaScript("document.getElementById('login').click()")
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(messages.submissions.count == 1)
        precondition(messages.submissions[0]["password"] as? String == "real-password")
        precondition(messages.submissions[0]["username"] as? String == "fixture-user")
        // Labels/IDs still exclude CAPTCHA when the site omits autocomplete.
        _ = try await view.evaluateJavaScript("document.getElementById('code').removeAttribute('autocomplete'); document.getElementById('code').value='987654'; document.getElementById('login').click()")
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(messages.submissions.count == 1, "Changing only CAPTCHA does not create a new credential")
        print("credential-code-fields-tests=passed")
    }
}
