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
            // 沙盒的 microphone 与硬运行时的 audio-input 是两条独立声明，
            // 只写其中一条时录音仍会被拦下。
            "com.apple.security.device.audio-input",
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

        let storeEntitlementsURL = root
            .appendingPathComponent("Lemon/Lemon-AppStore.entitlements")
        let storeData = try Data(contentsOf: storeEntitlementsURL)
        let storeEntitlements = try PropertyListSerialization.propertyList(
            from: storeData,
            format: nil
        ) as? [String: Any]
        precondition(storeEntitlements?["com.apple.security.app-sandbox"] as? Bool == true,
                     "App Store 版本必须启用沙盒")
        precondition(storeEntitlements?["com.apple.security.network.client"] as? Bool == true,
                     "App Store 浏览器必须允许网络客户端访问")
        precondition(storeEntitlements?["com.apple.security.network.server"] == nil,
                     "App Store 版本不应包含 360 迁移服务的网络监听权限")
        // 商店版同样要覆盖下载、本地文件、摄像头与麦克风；归档脚本另有产物断言。
        let storeRequired: [String] = [
            "com.apple.security.cs.allow-jit",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.downloads.read-write",
            "com.apple.security.files.bookmarks.app-scope",
            "com.apple.security.device.camera",
            "com.apple.security.device.microphone",
            "com.apple.security.device.audio-input",
        ]
        for key in storeRequired {
            precondition(storeEntitlements?[key] as? Bool == true,
                         "App Store 版本缺少 entitlement: \(key)")
        }

        let infoURL = root.appendingPathComponent("Lemon/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        precondition(info?["ITSAppUsesNonExemptEncryption"] as? Bool == false,
                     "仅使用豁免标准加密时 ITSAppUsesNonExemptEncryption 必须为 false")
        let ats = info?["NSAppTransportSecurity"] as? [String: Any]
        precondition(ats?["NSAllowsArbitraryLoads"] as? Bool == true,
                     "浏览器需要保持 NSAllowsArbitraryLoads（网页内容加载不受 ATS 限制）")

        let privacyURL = root.appendingPathComponent("Lemon/PrivacyInfo.xcprivacy")
        let privacyData = try Data(contentsOf: privacyURL)
        let privacy = try PropertyListSerialization.propertyList(
            from: privacyData,
            format: nil
        ) as? [String: Any]
        precondition(privacy?["NSPrivacyTracking"] as? Bool == false,
                     "Lemon 不跟踪用户")
        precondition((privacy?["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true,
                     "Lemon 不向开发者收集用户数据")
        let accessed = privacy?["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        precondition(accessed.contains {
            $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
                && ($0["NSPrivacyAccessedAPITypeReasons"] as? [String])?.contains("CA92.1") == true
        }, "必须声明 App 自身设置使用 UserDefaults")
        precondition(accessed.contains {
            $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryFileTimestamp"
                && ($0["NSPrivacyAccessedAPITypeReasons"] as? [String])?.contains("C617.1") == true
        }, "图标缓存与下载校验读取文件时间戳，必须声明 FileTimestamp 用途")

        print("sandbox-entitlements-tests=passed")
    }
}
