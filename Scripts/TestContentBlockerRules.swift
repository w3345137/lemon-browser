import Foundation

@main
struct TestContentBlockerRules {
    static func main() throws {
        let json = try ContentBlockerRules.jsonString()
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let rules = object as? [[String: Any]] else {
            fatalError("content blocker JSON must be an array of dictionaries")
        }
        precondition(rules.count == ContentBlockerRules.blockedURLFilters.count + 1)
        precondition(rules.contains { rule in
            ((rule["trigger"] as? [String: Any])?["url-filter"] as? String) == "doubleclick\\.net"
        })
        precondition(rules.contains { rule in
            ((rule["trigger"] as? [String: Any])?["url-filter"] as? String) == "cpro\\.baidu\\.com"
        })
        let hide = rules.last
        precondition((hide?["action"] as? [String: Any])?["type"] as? String == "css-display-none")
        precondition(((hide?["action"] as? [String: Any])?["selector"] as? String)?.contains("adsbygoogle") == true)
        print("content-blocker-rules-tests=passed")
    }
}
