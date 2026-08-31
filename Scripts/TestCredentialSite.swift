import Foundation

@main
struct TestCredentialSite {
    static func main() {
        precondition(CredentialStore.registrableDomain("www.xiaohongshu.com") == "xiaohongshu.com")
        precondition(CredentialStore.registrableDomain("login.xiaohongshu.com") == "xiaohongshu.com")
        precondition(CredentialStore.registrableDomain("mail.example.com.cn") == "example.com.cn")
        precondition(CredentialStore.sharesSite(
            origin: "https://login.xiaohongshu.com",
            with: URL(string: "https://www.xiaohongshu.com/explore")
        ))
        precondition(!CredentialStore.sharesSite(
            origin: "https://evil.example",
            with: URL(string: "https://www.xiaohongshu.com")
        ))
        print("credential-site-tests=passed")
    }
}
