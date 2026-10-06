import AppKit
import Foundation
import WebKit

private final class FaviconNetworkStub: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URL] = []

    static var requests: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "favicon-test.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.recorded.append(url)
        Self.lock.unlock()

        let status: Int
        let contentType: String
        let body: Data
        switch url.path {
        case "/favicon.ico":
            status = 404
            contentType = "text/plain"
            body = Data()
        case "/":
            status = 200
            contentType = "text/html; charset=utf-8"
            body = Data("<head><link rel='icon' href='/assets/logo.svg'></head>".utf8)
        case "/assets/logo.svg":
            status = 200
            contentType = "image/svg+xml"
            body = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='blue'/></svg>".utf8)
        default:
            status = 404
            contentType = "text/plain"
            body = Data()
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
enum TestFaviconIntegration {
    @MainActor static func main() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemon-favicon-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FaviconNetworkStub.self]
        FaviconService.testSession = URLSession(configuration: config)
        FaviconService.testCacheDirectory = directory
        let bookmark = URL(string: "https://favicon-test.example/private/page?secret=never-send")!
        let image = await withCheckedContinuation { continuation in
            FaviconService.load(for: bookmark) { continuation.resume(returning: $0) }
        }
        precondition(image != nil, "首页声明的 SVG 图标应该加载成功")
        let paths = FaviconNetworkStub.requests.map(\.path)
        precondition(paths == ["/favicon.ico", "/", "/assets/logo.svg"], "不得访问书签的私有路径：\(paths)")
        precondition(FaviconNetworkStub.requests.allSatisfy { $0.query == nil })
        precondition((try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) == 1)

        FaviconService.resetForTests()
        FaviconService.testSession = nil
        let restored = await withCheckedContinuation { continuation in
            FaviconService.load(for: bookmark) { continuation.resume(returning: $0) }
        }
        precondition(restored != nil, "图标应从本地磁盘缓存恢复")
        precondition(FaviconNetworkStub.requests.count == 3, "磁盘命中时不应重复请求")

        _ = NSApplication.shared
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        webView.loadHTMLString("<head><link rel='icon' href='/assets/logo.svg'></head>",
                               baseURL: URL(string: "https://favicon-test.example/"))
        for _ in 0..<40 {
            if (try? await webView.evaluateJavaScript("document.querySelector('link[rel=icon]')?.href")) as? String
                == "https://favicon-test.example/assets/logo.svg" { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        FaviconService.testSession = URLSession(configuration: config)
        let pageImage = await withCheckedContinuation { continuation in
            FaviconService.loadFromPage(bookmark, webView: webView) { continuation.resume(returning: $0) }
        }
        precondition(pageImage != nil, "已加载页面声明的图标应被采集")
        precondition(FaviconNetworkStub.requests.last?.path == "/assets/logo.svg")
        let requestCount = FaviconNetworkStub.requests.count
        let repeated = await withCheckedContinuation { continuation in
            FaviconService.loadFromPage(bookmark, webView: webView) { continuation.resume(returning: $0) }
        }
        precondition(repeated != nil && FaviconNetworkStub.requests.count == requestCount,
                     "同站点的已采集图标不应每次导航都重新下载")
        print("favicon-integration-tests=passed")
    }
}
