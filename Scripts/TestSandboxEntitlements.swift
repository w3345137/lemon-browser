import Foundation

/// 上架配置回归：entitlements 必须包含 App Sandbox 及 Lemon 功能所需的
/// 全部能力声明；Info.plist 必须有加密合规声明。
@main
struct TestSandboxEntitlements {
    static func main() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Scripts/
            .deletingLastPathComponent()   // repo root

        let entitlementsURL = root
            .appendingPathComponent("Lemon/Lemon.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any] else {
            preconditionFailure("Lemon.entitlements 不是字典")
        }

        let required: [String] = [
            "com.apple.security.app-sandbox",
            "com.apple.security.cs.allow-jit",
            "com.apple.security.network.client",
            "com.apple.security.network.server",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.downloads.read-write",
            "com.apple.security.files.bookmarks.app-scope",
            "com.apple.security.device.camera",
            "com.apple.security.device.microphone",
        ]
        for key in required {
            precondition(dict[key] as? Bool == true, "缺少 entitlement: \(key)")
        }
        // 不允许出现多余的高风险能力
        let forbidden: [String] = [
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.temporary-exception.shared-preference.read-write",
            "keychain-access-groups",
        ]
        for key in forbidden {
            precondition(dict[key] == nil, "不应包含 entitlement: \(key)")
        }

        let infoURL = root.appendingPathComponent("Lemon/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        precondition(info?["ITSAppUsesNonExemptEncryption"] as? Bool == true,
                     "缺少加密合规声明 ITSAppUsesNonExemptEncryption")
        let ats = info?["NSAppTransportSecurity"] as? [String: Any]
        precondition(ats?["NSAllowsArbitraryLoads"] as? Bool == true,
                     "浏览器需要保持 NSAllowsArbitraryLoads（网页内容加载不受 ATS 限制）")

        print("sandbox-entitlements-tests=passed")
    }
}
