import AppKit

enum FaviconService {
    private static let cache = NSCache<NSString, NSImage>()
    private static let transport = FaviconTransport()
    private static let session = URLSession(configuration: .ephemeral, delegate: transport, delegateQueue: nil)
    /// 站点没有任何可用 favicon 时的负缓存哨兵，避免每次打开同站页面都重新
    /// 等一遍超时。
    private static let missingMarker = NSImage()

    static func url(for page: URL) -> URL? {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil else { return nil }
        parts.user = nil
        parts.password = nil
        parts.path = "/favicon.ico"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    static func load(for page: URL, completion: @escaping (NSImage?) -> Void) {
        guard let iconURL = url(for: page) else {
            completion(nil)
            return
        }
        // Include scheme and port so unrelated origins do not share cache entries.
        let key = iconURL.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached === missingMarker ? nil : cached)
            return
        }

        let candidates = [iconURL]

        // Only the site's own icon is requested; missing icons use a local placeholder.
        let race = FaviconRace(candidateCount: candidates.count) { image in
            if let image {
                cache.setObject(image, forKey: key)
            } else {
                cache.setObject(missingMarker, forKey: key)
            }
            completion(image)
        }
        for candidate in candidates {
            var request = URLRequest(url: candidate)
            request.timeoutInterval = 3
            request.httpShouldHandleCookies = false
            session.dataTask(with: request) { data, response, _ in
                let validResponse = (response as? HTTPURLResponse)
                    .map { (200..<300).contains($0.statusCode) } ?? false
                if validResponse, let data, let image = NSImage(data: data), image.size.width > 0 {
                    race.finish(with: image)
                } else {
                    race.finish(with: nil)
                }
            }.resume()
        }
    }
}

private final class FaviconTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let target = request.url
        let sameOrigin = original?.scheme == target?.scheme && original?.host == target?.host && original?.port == target?.port
        completionHandler(sameOrigin ? request : nil)
    }
}

/// 第一个成功者立即交付；全部失败才交付 nil。线程安全。
private final class FaviconRace: @unchecked Sendable {
    private let lock = NSLock()
    private let completion: (NSImage?) -> Void
    private var delivered = false
    private var remaining: Int

    init(candidateCount: Int, completion: @escaping (NSImage?) -> Void) {
        self.completion = completion
        self.remaining = candidateCount
    }

    func finish(with image: NSImage?) {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered else { return }
        if image == nil {
            remaining -= 1
            if remaining > 0 { return }
        }
        delivered = true
        let completion = self.completion
        DispatchQueue.main.async {
            completion(image)
        }
    }
}
