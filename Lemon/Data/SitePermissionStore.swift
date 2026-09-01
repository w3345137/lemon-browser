import Foundation
import WebKit

enum SitePermissionChoice: String, Codable, CaseIterable, Identifiable {
    case ask
    case allow
    case block

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "询问"
        case .allow: "允许"
        case .block: "阻止"
        }
    }

    var webKitDecision: WKPermissionDecision {
        switch self {
        case .ask: .prompt
        case .allow: .grant
        case .block: .deny
        }
    }
}

enum SitePermissionKind: String, Codable, CaseIterable, Identifiable {
    case camera
    case microphone
    case popups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: "摄像头"
        case .microphone: "麦克风"
        case .popups: "弹出式窗口"
        }
    }

    var symbol: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .popups: "macwindow.on.rectangle"
        }
    }
}

@MainActor
final class SitePermissionStore: ObservableObject {
    static let shared = SitePermissionStore()

    @Published private var values: [String: SitePermissionChoice] = [:]
    private let defaultsKey = "sitePermissions.v1"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: SitePermissionChoice].self, from: data)
        else { return }
        values = decoded
    }

    func choice(for host: String, kind: SitePermissionKind) -> SitePermissionChoice {
        values[key(host: host, kind: kind)] ?? .ask
    }

    func set(_ choice: SitePermissionChoice, for host: String, kind: SitePermissionKind) {
        values[key(host: host, kind: kind)] = choice
        persist()
    }

    func externalApplicationChoice(for host: String, scheme: String) -> SitePermissionChoice {
        values[externalApplicationKey(host: host, scheme: scheme)] ?? .ask
    }

    func setExternalApplicationChoice(
        _ choice: SitePermissionChoice,
        for host: String,
        scheme: String
    ) {
        values[externalApplicationKey(host: host, scheme: scheme)] = choice
        persist()
    }

    func externalApplicationSchemes(for host: String) -> [String] {
        let prefix = "\(normalized(host)).externalApplication."
        return values.keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            return String(key.dropFirst(prefix.count))
        }.sorted()
    }

    func reset(host: String) {
        let prefix = "\(normalized(host))."
        values = values.filter { !$0.key.hasPrefix(prefix) }
        persist()
    }

    var configuredHosts: [String] {
        Array(Set(values.keys.compactMap(hostFromStoredKey))).sorted()
    }

    func hasCustomPermissions(for host: String) -> Bool {
        let prefix = "\(normalized(host))."
        return values.keys.contains(where: { $0.hasPrefix(prefix) })
    }

    func resetAll() {
        values = [:]
        persist()
    }

    private func key(host: String, kind: SitePermissionKind) -> String {
        "\(normalized(host)).\(kind.rawValue)"
    }

    private func externalApplicationKey(host: String, scheme: String) -> String {
        "\(normalized(host)).externalApplication.\(scheme.lowercased())"
    }

    private func hostFromStoredKey(_ key: String) -> String? {
        if let marker = key.range(of: ".externalApplication.") {
            return String(key[..<marker.lowerBound])
        }
        return SitePermissionKind.allCases.first(where: { key.hasSuffix(".\($0.rawValue)") })
            .map { String(key.dropLast($0.rawValue.count + 1)) }
    }

    private func normalized(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
