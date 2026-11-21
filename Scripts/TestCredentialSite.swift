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
        // 内嵌登录框只放行同站框架：Apple 登录 iframe 可以，其他站点不行。
        let asc = URL(string: "https://appstoreconnect.apple.com/login")
        precondition(CredentialStore.isSameSite(origin: "https://idmsa.apple.com", with: asc))
        precondition(!CredentialStore.isSameSite(origin: "https://idmsa.apple.com.evil.example", with: asc))
        precondition(!CredentialStore.isSameSite(origin: "http://idmsa.apple.com", with: asc))
        precondition(!CredentialStore.isSameSite(origin: "https://apple.com.cn", with: asc))
        precondition(!CredentialStore.isSameSite(
            origin: "https://attacker.github.io", with: URL(string: "https://victim.github.io")))
        precondition(!CredentialStore.isSameSite(
            origin: "https://a.vercel.app", with: URL(string: "https://b.vercel.app")))
        precondition(!CredentialStore.isSameSite(
            origin: "https://other.com.cn", with: URL(string: "https://www.example.com.cn")))
        precondition(CredentialStore.isSameSite(
            origin: "https://passport.example.com.cn", with: URL(string: "https://www.example.com.cn")))
        precondition(!CredentialStore.isSameSite(
            origin: "https://10.0.0.2", with: URL(string: "https://10.0.0.1")))
        precondition(CredentialStore.registrableDomain("victim.github.io") == "victim.github.io")
        print("credential-site-tests=passed")
    }
}
