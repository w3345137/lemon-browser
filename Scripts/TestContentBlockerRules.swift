import Foundation
import WebKit

@main
struct TestContentBlockerRules {
    @MainActor static func main() async throws {
        let json = try ContentBlockerRules.jsonString()
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let rules = object as? [[String: Any]] else {
            fatalError("content blocker JSON must be an array of dictionaries")
        }
        precondition(rules.count == ContentBlockerRules.blockedURLFilters.count + 1)
        let filters = rules.compactMap { rule -> String? in
            guard (rule["action"] as? [String: Any])?["type"] as? String == "block" else { return nil }
            return (rule["trigger"] as? [String: Any])?["url-filter"] as? String
        }
        let expressions = try filters.map { try NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        func blocked(_ url: String) -> Bool {
            expressions.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }
        for url in [
            "https://wx.mail.qq.com/ftn/download?func=3&k=synthetic-test-only",
            "https://mail.qq.com/", "https://notdoubleclick.net/",
            "https://doubleclick.net.example.org/", "https://example.org/doubleclick.net/file",
            "https://example.org/?next=https://l.qq.com/", "https://l.qq.com@example.org/",
            "https://example.org/#https://doubleclick.net/",
            "https://example.org/pagead2.google.com/"
        ] {
            precondition(!blocked(url), "legitimate URL falsely blocked: \(url)")
        }
        for url in [
            "https://l.qq.com/", "http://p.l.qq.com/ad", "https://l.qq.com:8443/ad",
            "https://doubleclick.net/", "https://sub.doubleclick.net/ad", "https://cpro.baidu.com/ad",
            "https://adservice.google.com/", "https://adservice.google.co.uk/ad",
            "https://pagead2.googlesyndication.com/ad", "https://DOUBLECLICK.NET/"
        ] {
            precondition(blocked(url), "advertising host no longer blocked: \(url)")
        }
        precondition(ContentBlockerRules.identifier != "com.lemon.browser.ads.v1")
        let hide = rules.last
        precondition((hide?["action"] as? [String: Any])?["type"] as? String == "css-display-none")
        precondition(((hide?["action"] as? [String: Any])?["selector"] as? String)?.contains("adsbygoogle") == true)
        let store = WKContentRuleListStore.default()!
        let identifier = "lemon-content-blocker-test-\(UUID().uuidString)"
        let compiled: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? ContentBlockerError.invalidRules) }
            }
        }
        precondition(compiled.identifier == identifier)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
        }
        print("content-blocker-rules-tests=passed")
    }
}
