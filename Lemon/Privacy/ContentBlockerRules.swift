import Foundation

enum ContentBlockerRules {
    static let identifier = "com.workbuddy.lemon.ads.v1"

    static let blockedURLFilters = [
        "doubleclick\\.net",
        "googleadservices\\.com",
        "googlesyndication\\.com",
        "googletagservices\\.com",
        "2mdn\\.net",
        "google-analytics\\.com",
        "adservice\\.google\\.",
        "pagead2\\.",
        "ads\\.yahoo\\.com",
        "ads-twitter\\.com",
        "static\\.ads-twitter\\.com",
        "ads\\.linkedin\\.com",
        "amazon-adsystem\\.com",
        "advertising\\.com",
        "adnxs\\.com",
        "adsrvr\\.org",
        "adsafeprotected\\.com",
        "casalemedia\\.com",
        "criteo\\.com",
        "criteo\\.net",
        "moatads\\.com",
        "openx\\.net",
        "outbrain\\.com",
        "pubmatic\\.com",
        "quantserve\\.com",
        "rubiconproject\\.com",
        "scorecardresearch\\.com",
        "taboola\\.com",
        "bidswitch\\.net",
        "creativecdn\\.com",
        "cpro\\.baidu\\.com",
        "pos\\.baidu\\.com",
        "eclick\\.baidu\\.com",
        "cbjs\\.baidu\\.com",
        "hm\\.baidu\\.com",
        "union\\.baidu\\.com",
        "dsp\\.youdao\\.com",
        "l\\.qq\\.com",
        "p\\.l\\.qq\\.com",
        "adnet\\.qq\\.com",
        "pgdt\\.gtimg\\.cn",
        "tanx\\.com",
        "alimama\\.com",
        "union\\.jd\\.com",
        "x\\.jd\\.com",
        "ads\\.union\\.jd\\.com",
        "pglstatp-toutiao\\.com",
        "pangolin-sdk-toutiao\\.com",
        "ad\\.xiaomi\\.com",
        "tracking\\.miui\\.com",
        "union\\.uc\\.cn",
        "cnzz\\.com",
        "umeng\\.com",
        "umengcloud\\.com",
        "gridsumdissector\\.com",
        "mediav\\.com",
        "ipinyou\\.com",
        "admaster\\.com\\.cn",
        "lianmeng\\.360\\.cn"
    ]

    static let hiddenSelectors = [
        "ins.adsbygoogle",
        ".adsbygoogle",
        "iframe[id^='google_ads']",
        "iframe[src*='doubleclick.net']",
        "iframe[src*='googlesyndication']",
        "iframe[src*='googleadservices']",
        "#google_ads_iframe",
        ".ad-banner",
        ".ad-wrapper",
        ".advertisement",
        "[data-ad-slot]",
        "[id='ad']",
        "[id='ads']"
    ].joined(separator: ", ")

    static func jsonString() throws -> String {
        var rules: [[String: Any]] = blockedURLFilters.map { filter in
            [
                "trigger": ["url-filter": filter],
                "action": ["type": "block"]
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": hiddenSelectors
            ]
        ])
        let data = try JSONSerialization.data(withJSONObject: rules)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ContentBlockerError.invalidRules
        }
        return json
    }
}

enum ContentBlockerError: LocalizedError {
    case invalidRules
    case compileFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRules:
            return "内容拦截规则无效。"
        case let .compileFailed(message):
            return message
        }
    }
}
