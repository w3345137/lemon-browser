import Foundation

enum SafariIdentity {
    /// WKWebView 默认 UA 只有 AppleWebKit 标识。追加本机 Safari 的产品标识，
    /// 让登录和风控系统按当前 Safari/WebKit 组合识别，同时避免固定旧版本号。
    static let applicationName: String = {
        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        let version = Bundle(url: safariURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let version, !version.isEmpty else { return "Safari/605.1.15" }
        return "Version/\(version) Safari/605.1.15"
    }()
}
