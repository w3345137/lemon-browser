import Foundation

enum SessionImportRequestPolicy {
    static func isAuthorizedImport(_ headers: String, token: String) -> Bool {
        guard !token.isEmpty,
              requestLine(in: headers) == "POST /import/\(token) HTTP/1.1",
              let origin = headerValue(named: "origin", in: headers),
              let originURL = URL(string: origin),
              originURL.scheme?.lowercased() == "chrome-extension",
              originURL.host?.isEmpty == false else {
            return false
        }
        return true
    }

    static func isPreflight(_ headers: String) -> Bool {
        requestLine(in: headers).hasPrefix("OPTIONS ")
    }

    private static func requestLine(in headers: String) -> String {
        headers.components(separatedBy: "\r\n").first ?? ""
    }

    private static func headerValue(named name: String, in headers: String) -> String? {
        let prefix = "\(name.lowercased()):"
        guard let line = headers
            .components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix(prefix) }) else {
            return nil
        }
        return line
            .split(separator: ":", maxSplits: 1)[1]
            .trimmingCharacters(in: .whitespaces)
    }
}
