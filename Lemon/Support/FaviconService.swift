import AppKit
import CryptoKit
import WebKit

extension Notification.Name {
    static let lemonFaviconDidUpdate = Notification.Name("com.lemon.browser.faviconDidUpdate")
}

/// Bookmark icons never require a third-party icon aggregator or a replay of
/// the saved page's path, query string, cookies, or credentials.
@MainActor
enum FaviconService {
    private static let cache = NSCache<NSString, NSImage>()
    private static var missingUntil: [String: Date] = [:]
    private static var pending: [String: [(NSImage?) -> Void]] = [:]
    private static var refreshing = Set<String>()
    private static var successfulDeclaredIcon: [String: URL] = [:]
    private static let negativeLifetime: TimeInterval = 120
    private static let diskLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumImageBytes = 1_048_576
    private static let maximumHTMLBytes = 262_144
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: FaviconTransport(), delegateQueue: nil)
    }()

    #if LEMON_TEST_COMPATIBILITY_RESOURCES
    static var testCacheDirectory: URL?
    static var testSession: URLSession?

    static func resetForTests() {
        cache.removeAllObjects()
        missingUntil.removeAll()
        pending.removeAll()
        refreshing.removeAll()
        successfulDeclaredIcon.removeAll()
    }
    #endif

    nonisolated static func url(for page: URL) -> URL? {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil else { return nil }
        parts.user = nil
        parts.password = nil
        parts.path = "/favicon.ico"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    nonisolated static func originKey(for page: URL) -> String? {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil else { return nil }
        parts.user = nil
        parts.password = nil
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url?.absoluteString
    }

    static func load(for page: URL, completion: @escaping (NSImage?) -> Void) {
        guard let key = originKey(for: page) else { completion(nil); return }
        if let image = cache.object(forKey: key as NSString) { completion(image); return }
        if let stored = storedImage(for: key) {
            cache.setObject(stored.image, forKey: key as NSString)
            completion(stored.image)
            if stored.age > diskLifetime { refresh(for: page, key: key) }
            return
        }
        if let retryAfter = missingUntil[key], retryAfter > Date() { completion(nil); return }
        if pending[key] != nil { pending[key]?.append(completion); return }
        pending[key] = [completion]
        Task {
            let data = await resolveIcon(for: page)
            let existing = cache.object(forKey: key as NSString)
            let image = existing ?? data.flatMap(validImage)
            if existing == nil, let image, let data {
                store(image: image, data: data, for: key)
            } else if image == nil {
                missingUntil[key] = Date().addingTimeInterval(negativeLifetime)
            }
            let callbacks = pending.removeValue(forKey: key) ?? []
            callbacks.forEach { $0(image) }
        }
    }

    /// Inspect only icon links in the already loaded main frame. No form
    /// values, cookies, page text, or URL query parameters are collected.
    static func loadFromPage(_ page: URL, webView: WKWebView, completion: @escaping (NSImage?) -> Void) {
        guard let key = originKey(for: page) else { completion(nil); return }
        webView.evaluateJavaScript("""
            [...document.querySelectorAll('link[rel][href]')]
              .filter(link => /(^|\\s)(icon|apple-touch-icon|apple-touch-icon-precomposed|mask-icon)(\\s|$)/i.test(link.rel))
              .slice(0, 16).map(link => link.href)
            """) { result, _ in
            Task { @MainActor in
                let rawURLs = result as? [String] ?? []
                let candidates = orderedUnique(rawURLs.compactMap {
                    safeIconURL($0, relativeTo: page, allowDeclaredCDN: true)
                })
                guard !candidates.isEmpty else { load(for: page, completion: completion); return }
                if let previous = successfulDeclaredIcon[key], candidates.contains(previous),
                   let image = cache.object(forKey: key as NSString) {
                    completion(image)
                    return
                }
                Task {
                    for candidate in candidates.prefix(8) {
                        guard let data = await fetchImageData(at: candidate),
                              let image = validImage(data) else { continue }
                        successfulDeclaredIcon[key] = candidate
                        store(image: image, data: data, for: key)
                        completion(image)
                        return
                    }
                    load(for: page, completion: completion)
                }
            }
        }
    }

    /// During background bookmark rendering, inspect only the origin's home
    /// page, never the saved bookmark's path or query.
    nonisolated static func declaredIconURLs(in html: String, page: URL) -> [URL] {
        let prefix: String
        if let headEnd = html.range(of: "</head", options: .caseInsensitive)?.lowerBound {
            prefix = String(html[..<headEnd])
        } else {
            prefix = String(html.prefix(131_072))
        }
        guard let tags = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: #"([a-zA-Z][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [] }
        let source = prefix as NSString
        var urls: [URL] = []
        for match in tags.matches(in: prefix, range: NSRange(location: 0, length: source.length)).prefix(64) {
            let tag = source.substring(with: match.range)
            let nsTag = tag as NSString
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)) {
                let name = nsTag.substring(with: attribute.range(at: 1)).lowercased()
                guard let valueRange = (2...4).map({ attribute.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
                values[name] = nsTag.substring(with: valueRange)
            }
            let relation = values["rel"]?.lowercased().split(whereSeparator: \.isWhitespace) ?? []
            guard relation.contains("icon") || relation.contains("apple-touch-icon")
                    || relation.contains("apple-touch-icon-precomposed") || relation.contains("mask-icon"),
                  let href = values["href"],
                  let url = safeIconURL(href, relativeTo: page, allowDeclaredCDN: true) else { continue }
            if !urls.contains(url) { urls.append(url) }
            if urls.count >= 8 { break }
        }
        return urls
    }

    private nonisolated static func safeIconURL(_ href: String, relativeTo page: URL,
                                                 allowDeclaredCDN: Bool) -> URL? {
        guard href.count <= 2048,
              let url = URL(string: href, relativeTo: page)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil, url.host != nil,
              !(page.scheme == "https" && scheme != "https") else { return nil }
        let sameOrigin = scheme == page.scheme?.lowercased()
            && url.host?.lowercased() == page.host?.lowercased()
            && url.port == page.port
        if !sameOrigin {
            guard allowDeclaredCDN, scheme == "https", let host = url.host?.lowercased(),
                  host != "localhost", !host.hasSuffix(".local"), !host.contains(":"),
                  host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil else { return nil }
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.url
    }

    private static func orderedUnique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    private static func resolveIcon(for page: URL) async -> Data? {
        guard let iconURL = url(for: page) else { return nil }
        if let data = await fetchImageData(at: iconURL) { return data }
        guard var home = URLComponents(url: iconURL, resolvingAgainstBaseURL: false) else { return nil }
        home.path = "/"
        guard let homeURL = home.url else { return nil }
        if let document = await fetchHTML(at: homeURL) {
            for candidate in declaredIconURLs(in: document.html, page: document.url) {
                if let data = await fetchImageData(at: candidate) { return data }
            }
        }
        return await fetchImageData(at: homeURL.appendingPathComponent("apple-touch-icon.png"))
    }

    private static func fetchImageData(at url: URL) async -> Data? {
        guard let (data, response) = await fetch(URLRequest(url: url), timeout: 4),
              (200..<300).contains(response.statusCode), validImage(data) != nil else { return nil }
        return data
    }

    private static func fetchHTML(at url: URL) async -> (html: String, url: URL)? {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-131071", forHTTPHeaderField: "Range")
        guard let (data, response) = await fetch(request, timeout: 4),
              (200..<300).contains(response.statusCode), data.count <= maximumHTMLBytes,
              let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.contains("html") else { return nil }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let resolvedURL = response.url else { return nil }
        return (html, resolvedURL)
    }

    private static func fetch(_ baseRequest: URLRequest, timeout: TimeInterval) async -> (Data, HTTPURLResponse)? {
        var request = baseRequest
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            #if LEMON_TEST_COMPATIBILITY_RESOURCES
            let client = testSession ?? session
            #else
            let client = session
            #endif
            let (data, response) = try await client.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (data, http)
        } catch { return nil }
    }

    private static func validImage(_ data: Data) -> NSImage? {
        guard !data.isEmpty, data.count <= maximumImageBytes,
              let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              image.size.width <= 8192, image.size.height <= 8192 else { return nil }
        return image
    }

    private static func refresh(for page: URL, key: String) {
        guard refreshing.insert(key).inserted else { return }
        Task {
            defer { refreshing.remove(key) }
            guard let data = await resolveIcon(for: page), let image = validImage(data) else { return }
            store(image: image, data: data, for: key)
        }
    }

    private static func store(image: NSImage, data: Data, for key: String) {
        cache.setObject(image, forKey: key as NSString)
        missingUntil.removeValue(forKey: key)
        let directory = cacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: fileURL(for: key), options: .atomic)
        NotificationCenter.default.post(name: .lemonFaviconDidUpdate, object: key, userInfo: ["image": image])
    }

    private static func storedImage(for key: String) -> (image: NSImage, age: TimeInterval)? {
        let file = fileURL(for: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int, size > 0, size <= maximumImageBytes,
              let data = try? Data(contentsOf: file), let image = validImage(data) else { return nil }
        let age = Date().timeIntervalSince(attrs[.modificationDate] as? Date ?? .distantPast)
        return (image, age)
    }

    private static var cacheDirectory: URL {
        #if LEMON_TEST_COMPATIBILITY_RESOURCES
        if let testCacheDirectory { return testCacheDirectory }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Lemon/Favicons", isDirectory: true)
    }

    private static func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest + ".image")
    }
}

enum FaviconRedirectPolicy {
    nonisolated static func allows(from source: URL?, to target: URL?) -> Bool {
        guard let source, let target,
              let sourceScheme = source.scheme?.lowercased(),
              let targetScheme = target.scheme?.lowercased(),
              ["http", "https"].contains(sourceScheme),
              ["http", "https"].contains(targetScheme),
              let host = source.host?.lowercased(), host == target.host?.lowercased(),
              source.user == nil, source.password == nil,
              target.user == nil, target.password == nil else { return false }
        let sourcePort = source.port ?? (sourceScheme == "https" ? 443 : 80)
        let targetPort = target.port ?? (targetScheme == "https" ? 443 : 80)
        if sourceScheme == targetScheme { return sourcePort == targetPort }
        return sourceScheme == "http" && targetScheme == "https"
            && sourcePort == 80 && targetPort == 443
    }
}

private final class FaviconTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Evaluate every hop against the current response, so an initial HTTP
        // request cannot authorize a later HTTPS-to-HTTP downgrade.
        completionHandler(FaviconRedirectPolicy.allows(from: response.url, to: request.url) ? request : nil)
    }
}
