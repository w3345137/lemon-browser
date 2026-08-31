import Foundation
import WebKit

// 下载相关测试独立编译 DownloadStore.swift 时，WebKitFactory 依赖的
// SafariIdentity / CredentialBridge / ContentBlocker 最小桩。
enum SafariIdentity {
    static let applicationName = "LemonDownloadTest"
}

enum CredentialBridge {
    static let captureScript = WKUserScript(
        source: "",
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )
}

final class ContentBlocker {
    static let shared = ContentBlocker()
    func install(on configuration: WKWebViewConfiguration) {}
}
