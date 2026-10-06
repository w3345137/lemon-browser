import Foundation

@main
enum TestFaviconPrivacy {
    static func main() {
        let source = URL(string: "https://user:secret@internal.example:8443/path?token=private#x")!
        precondition(FaviconService.url(for: source)?.absoluteString == "https://internal.example:8443/favicon.ico")
        precondition(FaviconService.originKey(for: source) == "https://internal.example:8443")
        precondition(FaviconService.originKey(for: URL(string: "https://internal.example:8443/other?different=1")!) == FaviconService.originKey(for: source))
        precondition(FaviconService.url(for: URL(fileURLWithPath: "/tmp/page.html")) == nil)
        precondition(FaviconService.url(for: URL(string: "about:blank")!) == nil)

        let home = URL(string: "https://example.com/")!
        let html = """
            <html><head>
            <link HREF='/assets/site.svg' sizes='any' REL='shortcut ICON'>
            <link rel="apple-touch-icon" href="https://static.example-cdn.com/apple.png">
            <link rel="icon" href="javascript:alert(1)">
            <link rel="icon" href="http://example.com/downgrade.png">
            <link rel="icon" href="https://127.0.0.1/private.png">
            </head><body><link rel="icon" href="/too-late.png"></body></html>
            """
        let icons = FaviconService.declaredIconURLs(in: html, page: home).map(\.absoluteString)
        precondition(icons == ["https://example.com/assets/site.svg", "https://static.example-cdn.com/apple.png"])
        func redirect(_ from: String, _ to: String) -> Bool {
            FaviconRedirectPolicy.allows(from: URL(string: from), to: URL(string: to))
        }
        precondition(redirect("http://movie.douban.com/favicon.ico", "https://movie.douban.com/favicon.ico"))
        precondition(redirect("http://example.com:80/icon", "https://example.com:443/icon"))
        precondition(redirect("https://example.com/icon", "https://example.com:443/new-icon"))
        precondition(!redirect("https://example.com/icon", "http://example.com/icon"))
        precondition(!redirect("http://example.com/icon", "https://other.example/icon"))
        precondition(!redirect("http://example.com:8080/icon", "https://example.com/icon"))
        precondition(!redirect("https://example.com/icon", "https://example.com:8443/icon"))
        precondition(!redirect("https://example.com/icon", "https://user:secret@example.com/icon"))
        print("favicon-privacy-tests=passed")
    }
}
