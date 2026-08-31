import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

@main
struct LemonApp: App {
    @NSApplicationDelegateAdaptor(LemonAppDelegate.self) private var appDelegate

    init() {
        LegacySandboxDataMigration.runIfNeeded()
        ContentBlocker.shared.prepare()
    }

    var body: some Scene {
        WindowGroup("Lemon", id: "main") {
            BrowserWindowView(isPrivate: false)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            BrowserCommands()
        }

        WindowGroup("无痕浏览", id: "private") {
            BrowserWindowView(isPrivate: true)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
        }
    }
}

struct BrowserCommands: Commands {
    @FocusedValue(\.browserState) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("新建无痕窗口") {
                openWindow(id: "private")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("新建标签页") {
                state?.openNewTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("重新打开关闭的标签页") {
                state?.reopenClosedTab()
            }
            .keyboardShortcut("e", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button("打开文件…") {
                state?.openLocalHTMLFile()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("打开位置…") {
                state?.focusAddressBarFromKeyboard()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("关闭标签页") {
                state?.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("切换到第 1 个标签") { state?.selectTab(number: 1) }
                .keyboardShortcut("1", modifiers: .command)
            Button("切换到第 2 个标签") { state?.selectTab(number: 2) }
                .keyboardShortcut("2", modifiers: .command)
            Button("切换到第 3 个标签") { state?.selectTab(number: 3) }
                .keyboardShortcut("3", modifiers: .command)
            Button("切换到第 4 个标签") { state?.selectTab(number: 4) }
                .keyboardShortcut("4", modifiers: .command)
            Button("切换到第 5 个标签") { state?.selectTab(number: 5) }
                .keyboardShortcut("5", modifiers: .command)
            Button("切换到第 6 个标签") { state?.selectTab(number: 6) }
                .keyboardShortcut("6", modifiers: .command)
            Button("切换到第 7 个标签") { state?.selectTab(number: 7) }
                .keyboardShortcut("7", modifiers: .command)
            Button("切换到第 8 个标签") { state?.selectTab(number: 8) }
                .keyboardShortcut("8", modifiers: .command)
            Button("切换到最后一个标签") { state?.selectTab(number: 9) }
                .keyboardShortcut("9", modifiers: .command)
        }

        CommandMenu("历史记录") {
            Button("显示所有历史记录") {
                state?.showHistory()
            }
            .keyboardShortcut("y", modifiers: .command)

            Divider()

            Button("后退") {
                state?.selectedTab?.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("前进") {
                state?.selectedTab?.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)

            Button("重新载入此页") {
                state?.selectedTab?.reload()
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("清除历史记录") {
                state?.history.clear()
            }
        }

        CommandMenu("下载") {
            Button("显示下载") {
                state?.showDownloads()
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Button("打开下载文件夹") {
                if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    NSWorkspace.shared.open(folder)
                }
            }
        }

        CommandMenu("书签") {
            Button("将当前网页加入收藏") {
                state?.requestBookmarkSave()
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("显示/隐藏书签栏") {
                state?.isBookmarkBarVisible.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Divider()

            Button("书签管理器") {
                SettingsNavigation.shared.selection = .bookmarks
                openSettings()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
        }

        CommandMenu("显示") {
            Button(NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
                   ? "退出全屏"
                   : "进入全屏") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])

            Divider()

            Button("显示/隐藏边栏") {
                state?.isSidebarVisible.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("放大") {
                state?.selectedTab?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("缩小") {
                state?.selectedTab?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("实际大小") {
                state?.selectedTab?.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(after: .textEditing) {
            Button("查找…") {
                state?.toggleFindBar()
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case bookmarks
    case passwords
    case websites

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .bookmarks: "书签"
        case .passwords: "密码"
        case .websites: "网站"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .bookmarks: "bookmark"
        case .passwords: "key"
        case .websites: "lock.shield"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()

    @Published var selection: SettingsSection = .general

    private init() {}
}

struct SettingsView: View {
    @StateObject private var defaultBrowser = DefaultBrowserManager()
    @ObservedObject private var contentBlocker = ContentBlocker.shared
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Text("设置")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 18)

                HStack(spacing: 4) {
                    ForEach(SettingsSection.allCases) { section in
                        Button {
                            navigation.selection = section
                        } label: {
                            Label(section.title, systemImage: section.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 104)
                        }
                        .buttonStyle(SettingsTopTabButtonStyle(isSelected: navigation.selection == section))
                    }
                }
            }
            .frame(height: 48)
            .background(Color(nsColor: .windowBackgroundColor))

            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 920, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { defaultBrowser.refresh() }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch navigation.selection {
        case .general:
            generalSettings
        case .bookmarks:
            BookmarkManagerView()
        case .passwords:
            PasswordSettingsView()
        case .websites:
            WebsiteDataSettingsView()
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("通用")
                        .font(.system(size: 20, weight: .semibold))
                    Text("默认浏览器、隐私与浏览行为")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 64)

            Divider()

            Form {
                Section("默认浏览器") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(defaultBrowser.isDefault ? "Lemon 已是默认浏览器" : "Lemon 不是默认浏览器")
                                .font(.body.weight(.medium))
                            Text("网页链接将使用 Lemon 打开。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(defaultBrowser.isDefault ? "已设为默认" : "设为默认浏览器") {
                            defaultBrowser.makeDefault()
                        }
                        .disabled(defaultBrowser.isDefault || defaultBrowser.isUpdating)
                    }
                    if let statusText = defaultBrowser.statusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(defaultBrowser.hasError ? Color.red : Color.secondary)
                    }
                }
                Section("隐私") {
                    Toggle("拦截广告和跟踪器", isOn: Binding(
                        get: { contentBlocker.isEnabled },
                        set: { contentBlocker.setEnabled($0) }
                    ))
                    Text(contentBlocker.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("关于 Lemon") {
                    LabeledContent("内核", value: "WebKit（与 Safari 同源）")
                    LabeledContent("地址栏", value: "回车后在新标签页打开")
                    LabeledContent("书签栏", value: "点击后在新标签页打开")
                }
                Text("页面里的链接仍在当前标签页打开。按住 ⌘ 再点链接，也会打开新标签页。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding(16)
        }
    }
}

private struct SettingsTopTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isSelected: isSelected)
    }

    private struct Surface: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(height: 48)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(surfaceColor)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                )
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.clear)
                        .frame(width: 72, height: 2)
                }
                .opacity(configuration.isPressed ? 0.72 : 1)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: isSelected)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .onHover { isHovering = $0 }
        }

        private var surfaceColor: Color {
            if configuration.isPressed { return Color.primary.opacity(0.09) }
            if isHovering { return Color.primary.opacity(0.055) }
            return .clear
        }
    }
}

@MainActor
private final class DefaultBrowserManager: ObservableObject {
    @Published private(set) var isDefault = false
    @Published private(set) var isUpdating = false
    @Published private(set) var statusText: String?
    @Published private(set) var hasError = false

    func refresh() {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            isDefault = false
            statusText = nil
            return
        }
        let identifier = Bundle(url: appURL)?.bundleIdentifier
        isDefault = identifier == Bundle.main.bundleIdentifier
        hasError = false
        if isDefault {
            let handlerPath = appURL.standardizedFileURL.path
            let currentPath = Bundle.main.bundleURL.standardizedFileURL.path
            if handlerPath == currentPath {
                statusText = "当前 HTTP 与 HTTPS 链接默认由 Lemon 打开。"
            } else {
                statusText = "HTTP 链接已交给 Lemon，但系统登记的是另一份副本：\(handlerPath)"
            }
        }
    }

    func makeDefault() {
        let bundleURL = preferredBundleURL()
        isUpdating = true
        statusText = "正在更新系统默认浏览器…"
        hasError = false
        LSRegisterURL(bundleURL as CFURL, true)
        let htmlTypes = [UTType.html, UTType("public.xhtml")].compactMap { $0 }
        setDefault(bundleURL, schemes: ["http", "https"], types: htmlTypes, index: 0)
    }

    private func preferredBundleURL() -> URL {
        let applications = URL(fileURLWithPath: "/Applications/Lemon.app")
        if FileManager.default.fileExists(atPath: applications.path) {
            return applications
        }
        return Bundle.main.bundleURL
    }

    private func setDefault(_ bundleURL: URL, schemes: [String], types: [UTType], index: Int) {
        if index < schemes.count {
            NSWorkspace.shared.setDefaultApplication(
                at: bundleURL,
                toOpenURLsWithScheme: schemes[index]
            ) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if error != nil {
                        _ = self.setWithLaunchServices(scheme: schemes[index])
                    }
                    self.setDefault(bundleURL, schemes: schemes, types: types, index: index + 1)
                }
            }
            return
        }

        let typeIndex = index - schemes.count
        if typeIndex < types.count {
            NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: types[typeIndex]) { [weak self] error in
                DispatchQueue.main.async {
                    _ = error
                    self?.setDefault(bundleURL, schemes: schemes, types: types, index: index + 1)
                }
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.isUpdating = false
            self.refresh()
            if self.isDefault {
                return
            }
            self.openDefaultBrowserSettings()
            self.statusText = "macOS 需要在系统设置里确认默认浏览器。请打开“桌面与程序坞”，把“默认网页浏览器”选为 Lemon。"
            self.hasError = true
        }
    }

    private func setWithLaunchServices(scheme: String) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return LSSetDefaultHandlerForURLScheme(
            scheme as CFString,
            bundleID as CFString
        ) == noErr
    }

    private func openDefaultBrowserSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.general",
            "x-apple.systempreferences:"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

private struct PasswordSettingsView: View {
    @ObservedObject private var store = CredentialStore.shared
    @ObservedObject private var sessionImporter = SessionImportServer.shared
    @State private var searchText = ""
    @State private var errorText: String?
    @State private var importStatus = ""

    private var filteredCredentials: [WebCredential] {
        guard !searchText.isEmpty else { return store.credentials }
        return store.credentials.filter {
            $0.displayHost.localizedCaseInsensitiveContains(searchText)
                || $0.displayUsername.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已保存的密码")
                        .font(.title3.weight(.semibold))
                    Text("密码加密保存在 macOS Keychain，此处只显示网站和账号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.credentials.count) 项")
                    .foregroundStyle(.secondary)
            }

            TextField("搜索网站或账号", text: $searchText)
                .textFieldStyle(.roundedBorder)

            GroupBox("从 360 浏览器迁移") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Button("导入密码 CSV…") { importPasswords() }
                        Text("导入后，CSV 会移到废纸篓。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    HStack {
                        Button(sessionImporter.isListening ? "停止接收" : "接收 360 数据") {
                            if sessionImporter.isListening {
                                sessionImporter.stop()
                            } else {
                                do {
                                    try sessionImporter.start()
                                } catch {
                                    errorText = error.localizedDescription
                                }
                            }
                        }
                        if sessionImporter.isListening {
                            Text(sessionImporter.token)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Button("复制口令") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sessionImporter.token, forType: .string)
                            }
                            .buttonStyle(.borderless)
                        }
                        Spacer()
                        Button("显示临时扩展") { revealSessionBridge() }
                    }

                    if !importStatus.isEmpty {
                        Text(importStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !sessionImporter.statusText.isEmpty {
                        Text(sessionImporter.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            List(filteredCredentials) { credential in
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credential.displayHost)
                        Text(credential.displayUsername)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        do {
                            try store.delete(credential)
                        } catch {
                            errorText = error.localizedDescription
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除此密码")
                }
                .padding(.vertical, 3)
            }
            .overlay {
                if filteredCredentials.isEmpty {
                    ContentUnavailableView("暂无密码", systemImage: "key.slash")
                }
            }
        }
        .padding(18)
        .alert("无法删除密码", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func importPasswords() {
        let panel = NSOpenPanel()
        panel.title = "选择 360 导出的密码 CSV"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try PasswordCSVImporter.importFile(at: url, into: store)
            var recycledURL: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &recycledURL)
                importStatus = "已把 \(result.imported) 项密码存入 macOS Keychain，跳过 \(result.skipped) 项；CSV 已移到废纸篓。"
            } catch {
                importStatus = "已把 \(result.imported) 项密码存入 macOS Keychain，跳过 \(result.skipped) 项。CSV 未能移到废纸篓，请手动删除。"
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func revealSessionBridge() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        let bridgeURL = resourceURL.appendingPathComponent("360SessionBridge", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bridgeURL.path) else {
            errorText = "交付包中缺少 360SessionBridge 临时扩展。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([bridgeURL])
    }
}

private struct BrowserStateKey: FocusedValueKey {
    typealias Value = BrowserWindowState
}

extension FocusedValues {
    var browserState: BrowserWindowState? {
        get { self[BrowserStateKey.self] }
        set { self[BrowserStateKey.self] = newValue }
    }
}
