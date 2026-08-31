import Foundation

enum URLInput {
    /// 空输入返回 nil，由调用方决定是否忽略；避免回车误开 apple.com。
    static func destination(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }

        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https", url.host != nil {
            return url
        }

        if looksLikeAddress(trimmed) {
            let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            if let url = URL(string: withScheme), url.host != nil {
                return url
            }
        }

        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url!
    }

    static func simplifiedHost(from url: URL?) -> String {
        guard let url else { return "" }
        let host = url.host ?? ""
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    static func displayPieces(from url: URL?) -> (host: String, path: String) {
        guard let url else { return ("", "") }
        let host = simplifiedHost(from: url)
        var path = url.path
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }
        if path == "/" { path = "" }
        return (host, path)
    }

    private static func looksLikeAddress(_ text: String) -> Bool {
        if text.contains(" ") { return false }
        if text.hasPrefix("localhost") { return true }
        if text.contains("://") { return true }
        let hostPart = text.split(separator: "/").first.map(String.init) ?? text
        if hostPart.contains(":") && !hostPart.contains(" ") { return true }
        return hostPart.contains(".")
    }
}
