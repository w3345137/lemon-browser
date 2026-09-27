import Foundation

@main
enum TestFaviconPrivacy {
    static func main() {
        let source = URL(string: "https://user:secret@internal.example:8443/path?token=private#x")!
        precondition(FaviconService.url(for: source)?.absoluteString == "https://internal.example:8443/favicon.ico")
        precondition(FaviconService.url(for: URL(fileURLWithPath: "/tmp/page.html")) == nil)
        precondition(FaviconService.url(for: URL(string: "about:blank")!) == nil)
        print("favicon-privacy-tests=passed")
    }
}
