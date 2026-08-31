import AppKit

enum FaviconService {
    private static let cache = NSCache<NSString, NSImage>()
    /// 站点没有任何可用 favicon 时的负缓存哨兵，避免每次打开同站页面都重新
    /// 等一遍（不可达的 google 源在国内要等满超时）。
    private static let missingMarker = NSImage()

    static func url(for page: URL) -> URL? {
        guard let host = page.host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }

    static func load(for page: URL, completion: @escaping (NSImage?) -> Void) {
        guard let host = page.host else {
            completion(nil)
            return
        }
        // 缓存按 host 而不是整页 URL：同一站点的每个页面不应反复请求。
        let key = host as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached === missingMarker ? nil : cached)
            return
        }

        var candidates: [URL] = []
        if let scheme = page.scheme,
           let direct = URL(string: "\(scheme)://\(host)/favicon.ico") {
            candidates.append(direct)
        }
        if let google = url(for: page) { candidates.append(google) }
        if let fallback = URL(string: "https://www.google.com/s2/favicons?domain_url=https://\(host)&sz=128") {
            candidates.append(fallback)
        }

        // 候选并行竞速：站点自己的 favicon.ico 通常最先成功，立即返回，
        // 不必再串行等待其余（可能不可达）的源各耗一遍超时。
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
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let validResponse = (response as? HTTPURLResponse)
                    .map { (200..<400).contains($0.statusCode) } ?? false
                if validResponse, let data, let image = NSImage(data: data), image.size.width > 0 {
                    race.finish(with: image)
                } else {
                    race.finish(with: nil)
                }
            }.resume()
        }
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
