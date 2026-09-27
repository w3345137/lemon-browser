import Foundation

@main
struct TestCredentialSite {
    static func main() {
        precondition(CredentialStore.registrableDomain("www.xiaohongshu.com") == "xiaohongshu.com")
        precondition(CredentialStore.registrableDomain("login.xiaohongshu.com") == "xiaohongshu.com")
        precondition(CredentialStore.registrableDomain("mail.example.com.cn") == "example.com.cn")
        precondition(!CredentialStore.sharesSite(
            origin: "https://login.xiaohongshu.com",
            with: URL(string: "https://www.xiaohongshu.com/explore")
        ))
        precondition(!CredentialStore.sharesSite(
            origin: "https://evil.example",
            with: URL(string: "https://www.xiaohongshu.com")
        ))
        for pair in [
            ("https://victim.github.io", "https://other.github.io"),
            ("https://bank.co.jp", "https://unrelated.co.jp"),
            ("https://login.example.com", "http://login.example.com"),
            ("https://example.com:8443", "https://example.com")
        ] {
            precondition(!CredentialStore.sharesSite(origin: pair.0, with: URL(string: pair.1)))
        }
        precondition(CredentialStore.sharesSite(origin: "https://example.com:443", with: URL(string: "https://example.com/login")))
        print("credential-site-tests=passed")
    }
}
