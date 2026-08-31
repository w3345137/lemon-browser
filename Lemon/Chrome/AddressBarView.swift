import AppKit
import SwiftUI

struct AddressBarView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var state: BrowserWindowState
    @ObservedObject private var credentialStore = CredentialStore.shared
    @ObservedObject private var downloads: DownloadStore
    var addressFocused: FocusState<Bool>.Binding
    @State private var showingHistory = false
    @State private var showingDownloads = false
    @State private var showingSiteInfo = false

    init(state: BrowserWindowState, addressFocused: FocusState<Bool>.Binding) {
        self.state = state
        self.addressFocused = addressFocused
        _downloads = ObservedObject(wrappedValue: state.downloads)
    }

    var body: some View {
        HStack(spacing: 7) {
            navigationButton("chevron.left", disabled: !(state.selectedTab?.canGoBack ?? false), help: "后退") {
                state.selectedTab?.goBack()
            }
            navigationButton("chevron.right", disabled: !(state.selectedTab?.canGoForward ?? false), help: "前进") {
                state.selectedTab?.goForward()
            }
            reloadButton

            pill
                .frame(maxWidth: .infinity)

            utilityButton("gearshape", help: "设置") {
                openSettings()
            }

            utilityButton("clock.arrow.circlepath", help: "历史记录") {
                showingHistory.toggle()
            }
            .popover(isPresented: $showingHistory, arrowEdge: .top) {
                HistoryPanel(state: state)
            }

            Button { showingDownloads.toggle() } label: {
                DownloadToolbarIcon(
                    isActive: downloads.hasActiveDownloads,
                    progress: downloads.activeProgress
                )
            }
            .buttonStyle(ToolbarIconButtonStyle())
            .help(downloads.hasActiveDownloads ? "下载中" : "下载")
            .popover(isPresented: $showingDownloads, arrowEdge: .top) {
                DownloadsPanel(state: state)
            }

            Menu {
                Button("新建标签页") { state.openNewTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("重新打开关闭的标签页") { state.reopenClosedTab() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(state.closedTabs.isEmpty)
                Divider()
                Button("历史记录") { state.showHistory() }
                Button("下载") { state.showDownloads() }
                Button("书签管理器") {
                    SettingsNavigation.shared.selection = .bookmarks
                    openSettings()
                }
                Button(state.isBookmarkBarVisible ? "隐藏书签栏" : "显示书签栏") {
                    state.isBookmarkBarVisible.toggle()
                }
                Divider()
                Button("查找…") { state.toggleFindBar() }
                Button("设置…") { openSettings() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(ToolbarIconButtonStyle())
            .fixedSize()
            .help("设置及更多")
        }
        .padding(.horizontal, 12)
    }

    private func navigationButton(
        _ systemName: String,
        disabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(disabled ? 0.24 : 0.78))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.001)))
                .contentShape(Circle())
        }
        .buttonStyle(ToolbarIconButtonStyle())
        .disabled(disabled)
        .help(help)
    }

    private var reloadButton: some View {
        let loading = state.selectedTab?.isLoading ?? false
        return Button {
            state.selectedTab?.reload()
        } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !loading)) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 0.85) / 0.85
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .rotationEffect(.degrees(loading ? cycle * 360 : 0))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(ToolbarIconButtonStyle())
        .help(loading ? "停止载入" : "重新载入")
    }

    private func utilityButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.80))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarIconButtonStyle())
        .help(help)
    }

    private var pill: some View {
        HStack(spacing: 9) {
            leadingIcon

            if state.isAddressEditing {
                TextField("搜索或输入网址", text: $state.addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused(addressFocused)
                    .onSubmit {
                        state.submitAddress(state.addressText)
                        addressFocused.wrappedValue = false
                    }
            } else {
                Button(action: state.handleAddressBarClick) {
                    idleLabel
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let tab = state.selectedTab, tab.hasLoadedPage, !state.isAddressEditing {
                let siteCredentials = credentialStore.credentials(for: tab.url)
                if !siteCredentials.isEmpty {
                    Menu {
                        ForEach(siteCredentials) { credential in
                            Button(credential.displayUsername) { state.fillCredential(credential) }
                        }
                    } label: {
                        Image(systemName: "key.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(ToolbarIconButtonStyle(size: 24, cornerRadius: 6))
                    .fixedSize()
                    .help("填充已保存的账号密码")
                }

                Button(action: state.toggleFavorite) {
                    Image(systemName: state.bookmarks.isFavorite(tab.url) ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(state.bookmarks.isFavorite(tab.url) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(ToolbarIconButtonStyle(size: 24, cornerRadius: 6))
                .help("将当前网页加入收藏")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(pillBackground)
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(
                state.isAddressEditing ? Color.accentColor.opacity(0.62) : Color.primary.opacity(0.12),
                lineWidth: state.isAddressEditing ? 1.5 : 0.7
            )
        )
        .shadow(color: .black.opacity(0.045), radius: 2, y: 1)
        .contextMenu {
            if let url = state.selectedTab?.url {
                Button("拷贝链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Divider()
                Button("清除此网站的数据…") { state.clearCurrentWebsiteData() }
            }
            Button("在新标签页粘贴并打开") {
                if let text = NSPasteboard.general.string(forType: .string),
                   let destination = URLInput.destination(from: text) {
                    state.openInNewTab(destination)
                }
            }
        }
    }

    private var pillBackground: some View {
        ZStack {
            Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(0.94))
            if state.selectedTab?.isLoading == true,
               let progress = state.selectedTab?.estimatedProgress,
               progress > 0,
               progress < 1 {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.13))
                        .frame(width: geo.size.width * progress)
                }
                .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if state.selectedTab?.isStartPage == true || state.isAddressEditing {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            Button {
                showingSiteInfo.toggle()
            } label: {
                let scheme = state.selectedTab?.url?.scheme?.lowercased()
                Image(systemName: SiteSecurityBadge.symbol(for: scheme))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SiteSecurityBadge.color(for: scheme))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(ToolbarIconButtonStyle(size: 24, cornerRadius: 6))
            .help("网站信息和权限")
            .popover(isPresented: $showingSiteInfo, arrowEdge: .top) {
                SiteInformationPanel(state: state)
            }
        }
    }

    private var idleLabel: some View {
        Group {
            if let url = state.selectedTab?.url {
                Text(url.absoluteString)
                    .foregroundStyle(.primary)
            } else {
                Text("搜索或输入网址")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13.5))
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

/// Chromium 式工具栏交互面：静止时保持透明，悬浮时出现克制底色，
/// 按下时进一步加深并轻微收缩，让图标按钮有明确但不喧闹的手感。
private struct ToolbarIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        Surface(
            configuration: configuration,
            size: size,
            cornerRadius: cornerRadius
        )
    }

    private struct Surface: View {
        let configuration: Configuration
        let size: CGFloat
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            configuration.isPressed && isEnabled
                                ? Color.primary.opacity(0.08)
                                : Color.clear,
                            lineWidth: 0.7
                        )
                )
                .scaleEffect(configuration.isPressed && isEnabled ? 0.94 : 1)
                .opacity(isEnabled ? 1 : 0.55)
                .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .onHover { isHovering = $0 }
        }

        private var backgroundColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Color.primary.opacity(0.13) }
            if isHovering { return Color.primary.opacity(0.075) }
            return .clear
        }
    }
}

private struct DownloadToolbarIcon: View {
    let isActive: Bool
    let progress: Double?

    var body: some View {
        ZStack {
            if isActive, let progress {
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1.7)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.78))
            } else if isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.80))
            }
        }
        .frame(width: 18, height: 18)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .accessibilityLabel(isActive ? "下载中" : "下载")
        .accessibilityValue(progress.map { "\(Int($0 * 100))%" } ?? "")
    }
}

/// 地址栏与网站信息面板共用的连接标识。本地 file:// 页面是 App 自己打开的
/// 功能（⌘O / Finder），不该按“不安全连接”显示警告三角。
private enum SiteSecurityBadge {
    static func symbol(for scheme: String?) -> String {
        switch scheme {
        case "https": "slider.horizontal.3"
        case "file": "folder"
        default: "exclamationmark.triangle.fill"
        }
    }

    static func color(for scheme: String?) -> Color {
        switch scheme {
        case "https", "file": .secondary
        default: .orange
        }
    }

    static func headlineText(for scheme: String?) -> String {
        switch scheme {
        case "https": "连接已加密"
        case "file": "本地文件"
        default: "此连接未使用 HTTPS"
        }
    }

    static func headlineSymbol(for scheme: String?) -> String {
        switch scheme {
        case "https": "lock.shield.fill"
        case "file": "folder.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    static func headlineColor(for scheme: String?) -> Color {
        switch scheme {
        case "https": .green
        case "file": .secondary
        default: .orange
        }
    }
}

private struct SiteInformationPanel: View {
    @ObservedObject var state: BrowserWindowState
    @ObservedObject private var permissions = SitePermissionStore.shared

    private var host: String {
        state.selectedTab?.url?.host ?? "当前网站"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                let scheme = state.selectedTab?.url?.scheme?.lowercased()
                Image(systemName: SiteSecurityBadge.headlineSymbol(for: scheme))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SiteSecurityBadge.headlineColor(for: scheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text(host)
                        .font(.system(size: 14, weight: .semibold))
                    Text(SiteSecurityBadge.headlineText(for: scheme))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)

            Divider()

            VStack(spacing: 2) {
                ForEach(SitePermissionKind.allCases) { kind in
                    HStack(spacing: 10) {
                        Image(systemName: kind.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(kind.title)
                            .font(.system(size: 12.5))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { permissions.choice(for: host, kind: kind) },
                            set: { permissions.set($0, for: host, kind: kind) }
                        )) {
                            ForEach(SitePermissionChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 92)
                    }
                    .frame(height: 34)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            Divider()

            HStack {
                Button("重置权限") {
                    permissions.reset(host: host)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("清除网站数据…") {
                    state.clearCurrentWebsiteData()
                }
                .buttonStyle(.bordered)
            }
            .font(.system(size: 12))
            .padding(12)
        }
        .frame(width: 340)
    }
}
