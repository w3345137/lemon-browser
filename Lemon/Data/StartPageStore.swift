import Combine
import Foundation

enum StartPageModule: String, CaseIterable, Codable, Identifiable {
    case shortcuts, favorites, recents
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shortcuts: "常用网页"
        case .favorites: "收藏"
        case .recents: "最近访问"
        }
    }
}

struct StartPageShortcut: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var url: URL
}

@MainActor
final class StartPageStore: ObservableObject {
    static let shared = StartPageStore()
    struct Configuration: Codable, Equatable {
        var version = 1
        var visibleModules = Set(StartPageModule.allCases)
        var shortcuts: [StartPageShortcut] = []
    }
    enum EditError: LocalizedError {
        case invalidURL, duplicateURL, missingShortcut, unreadable
        var errorDescription: String? {
            switch self {
            case .invalidURL: "请输入有效的 HTTP 或 HTTPS 网页地址，不支持脚本、文件或含账号密码的地址。"
            case .duplicateURL: "这个网页已添加到常用网页。"
            case .missingShortcut: "这个网页已被移除，请重新打开编辑窗口。"
            case .unreadable: "起始页配置无法读取，已保留原文件并停止写入。请检查文件权限或恢复备份后重启。"
            }
        }
    }

    @Published private(set) var configuration = Configuration()
    @Published private(set) var storageError: String?
    private let storageURL: URL?
    private var storageReadable = true

    init(storageURL: URL? = nil, inMemory: Bool = false) {
        self.storageURL = inMemory ? nil : (storageURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Lemon/start-page.json"))
        guard let url = self.storageURL else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Configuration.self, from: data)
            guard decoded.version == 1,
                  Set(decoded.shortcuts.map(\.id)).count == decoded.shortcuts.count,
                  decoded.shortcuts.allSatisfy({ Self.validatedURL($0.url.absoluteString) != nil }) else {
                throw EditError.unreadable
            }
            configuration = decoded
        } catch {
            if (error as? CocoaError)?.code != .fileReadNoSuchFile {
                storageReadable = false
                storageError = EditError.unreadable.localizedDescription
            }
        }
    }

    func isVisible(_ module: StartPageModule) -> Bool { configuration.visibleModules.contains(module) }

    func setVisible(_ module: StartPageModule, _ visible: Bool) throws {
        var updated = configuration
        if visible { updated.visibleModules.insert(module) }
        else { updated.visibleModules.remove(module) }
        try commit(updated)
    }

    @discardableResult
    func saveShortcut(id: UUID? = nil, title: String, address: String) throws -> StartPageShortcut {
        guard let url = Self.validatedURL(address) else { throw EditError.invalidURL }
        var updated = configuration
        guard !updated.shortcuts.contains(where: { $0.url == url && $0.id != id }) else {
            throw EditError.duplicateURL
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortcut = StartPageShortcut(id: id ?? UUID(), title: trimmed.isEmpty ? (url.host ?? address) : trimmed, url: url)
        if let id {
            guard let index = updated.shortcuts.firstIndex(where: { $0.id == id }) else { throw EditError.missingShortcut }
            updated.shortcuts[index] = shortcut
        } else {
            updated.shortcuts.append(shortcut)
        }
        updated.visibleModules.insert(.shortcuts)
        try commit(updated)
        return shortcut
    }

    func removeShortcut(_ id: UUID) throws {
        var updated = configuration
        updated.shortcuts.removeAll { $0.id == id }
        try commit(updated)
    }

    func moveShortcut(_ id: UUID, by offset: Int) throws {
        var updated = configuration
        guard let source = updated.shortcuts.firstIndex(where: { $0.id == id }) else { throw EditError.missingShortcut }
        let target = min(max(0, source + offset), updated.shortcuts.count - 1)
        guard source != target else { return }
        let shortcut = updated.shortcuts.remove(at: source)
        updated.shortcuts.insert(shortcut, at: target)
        try commit(updated)
    }

    /// 恢复模块显示，不清除用户已添加的网页。
    func restoreModules() throws {
        var updated = configuration
        updated.visibleModules = Set(StartPageModule.allCases)
        try commit(updated)
    }

    static func validatedURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let address = text.hasPrefix("//") ? "https:\(text)" : (text.contains("://") ? text : "https://\(text)")
        guard let parts = URLComponents(string: address),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              parts.user == nil, parts.password == nil,
              let url = parts.url else { return nil }
        return url
    }

    private func commit(_ updated: Configuration) throws {
        guard storageReadable else { throw EditError.unreadable }
        guard updated != configuration else { return }
        do {
            if let url = storageURL {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            }
            configuration = updated
            storageError = nil
        } catch {
            storageError = "无法保存起始页配置，修改未生效：\(error.localizedDescription)"
            throw error
        }
    }
}
