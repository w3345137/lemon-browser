import AppKit
import SwiftUI

struct StartPageView: View {
    @ObservedObject var state: BrowserWindowState
    @ObservedObject private var layout: StartPageStore
    @ObservedObject private var bookmarks: BookmarkStore
    @ObservedObject private var history: HistoryStore
    @State private var showingCustomization = false
    @State private var shortcutEditor: ShortcutEditorDraft?
    @State private var errorText: String?

    init(state: BrowserWindowState) {
        self.state = state
        _layout = ObservedObject(wrappedValue: state.startPage)
        _bookmarks = ObservedObject(wrappedValue: state.bookmarks)
        _history = ObservedObject(wrappedValue: state.history)
    }

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Spacer().frame(height: 12)
                    HStack {
                        Spacer()
                        Button { showingCustomization.toggle() } label: {
                            Label("编辑起始页", systemImage: "slider.horizontal.3")
                        }
                        .accessibilityIdentifier("start-page-customize")
                        .popover(isPresented: $showingCustomization, arrowEdge: .bottom) { customization }
                    }
                    header
                    if layout.isVisible(.shortcuts) { shortcuts }
                    if layout.isVisible(.favorites) { favorites }
                    if !state.isPrivate && layout.isVisible(.recents) {
                        recents
                    }
                    if state.isPrivate {
                        privateCard
                    }
                    if layout.configuration.visibleModules.isEmpty {
                        Text("所有模块已隐藏，可通过右上角“编辑起始页”恢复。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    if let error = layout.storageError {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
            }
        }
        .sheet(item: $shortcutEditor) { draft in
            StartPageShortcutEditor(store: layout, draft: draft)
        }
        .alert("无法修改起始页", isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } }
        )) { Button("好") { errorText = nil } } message: { Text(errorText ?? "") }
    }

    private func edit(_ action: () throws -> Void) {
        do { try action() } catch { errorText = error.localizedDescription }
    }

    private var customization: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑起始页").font(.headline)
            Text("选择要显示的模块，移除模块不会删除书签或历史。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(StartPageModule.allCases.filter { !state.isPrivate || $0 != .recents }) { module in
                Toggle(module.title, isOn: Binding(
                    get: { layout.isVisible(module) },
                    set: { value in edit { try layout.setVisible(module, value) } }
                ))
                .accessibilityIdentifier("start-page-module-\(module.rawValue)")
            }
            Divider()
            Button("添加网页…") {
                showingCustomization = false
                shortcutEditor = ShortcutEditorDraft()
            }
            Button("恢复所有模块") { edit { try layout.restoreModules() } }
            if state.isPrivate || state.isDemo {
                Text("此窗口的配置只临时保留，不会改变个人起始页。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(width: 300)
    }

    private func moduleHeader(_ module: StartPageModule) -> some View {
        HStack {
            Text(module.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("移除此模块") { edit { try layout.setVisible(module, false) } }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("\(module.title)模块操作")
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            moduleHeader(.shortcuts)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 18)], spacing: 18) {
                ForEach(Array(layout.configuration.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    FavoriteTile(item: BookmarkItem(id: shortcut.id, title: shortcut.title, url: shortcut.url)) {
                        state.openInNewTab(shortcut.url)
                    }
                    .contextMenu {
                        Button("编辑网页…") { shortcutEditor = ShortcutEditorDraft(shortcut: shortcut) }
                        Button("向前移动") { edit { try layout.moveShortcut(shortcut.id, by: -1) } }
                            .disabled(index == 0)
                        Button("向后移动") { edit { try layout.moveShortcut(shortcut.id, by: 1) } }
                            .disabled(index + 1 == layout.configuration.shortcuts.count)
                        Divider()
                        Button("删除网页", role: .destructive) { edit { try layout.removeShortcut(shortcut.id) } }
                    }
                }
                Button { shortcutEditor = ShortcutEditorDraft() } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 24))
                            .frame(width: 60, height: 60)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        Text("添加网页").font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
            }
            if layout.configuration.shortcuts.isEmpty {
                Text("添加自己常用的网页，名称和网址都可以随时修改。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var background: some View {
        ZStack {
            if state.isPrivate && !state.isDemo {
                Color(red: 0.10, green: 0.10, blue: 0.12)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            LinearGradient(
                colors: state.isPrivate && !state.isDemo
                    ? [Color.white.opacity(0.04), .clear]
                    : [Color.white.opacity(0.62), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .center, spacing: 5) {
            Text(state.isDemo ? "演示窗口" : (state.isPrivate ? "无痕浏览" : "起始页"))
                .font(.system(size: 30, weight: .semibold))
            Text(state.isDemo ? "临时浏览环境，不载入个人书签、历史或登录信息。" : (state.isPrivate ? "此窗口不会保存历史记录、搜索和自动填充信息。" : "地址栏和书签会在新标签页打开。"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 28)
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 14) {
            moduleHeader(.favorites)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 6), spacing: 18) {
                ForEach(bookmarks.favorites.prefix(12)) { item in
                    FavoriteTile(item: item) {
                        state.openBookmark(item)
                    }
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
        )
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 12) {
            moduleHeader(.recents)
            ForEach(history.entries.prefix(8)) { entry in
                Button {
                    state.openInNewTab(entry.url)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(entry.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if history.entries.isEmpty {
                Text("浏览网页后，最近访问会出现在这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
        )
    }

    private var privateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(state.isDemo ? "演示窗口使用临时 WebKit 数据容器" : "无痕窗口使用单独的 WebKit 数据容器", systemImage: "eye.slash")
                .font(.system(size: 14, weight: .medium))
            Text("关闭窗口后，此会话的 Cookie、缓存和历史都不会留下。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FavoriteTile: View {
    let item: BookmarkItem
    let onOpen: () -> Void
    @State private var favicon: NSImage?

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 28, height: 28)
                    } else {
                        Text(String(item.title.prefix(1)))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.75))
                    }
                }
                .frame(width: 60, height: 60)
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.82))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .task(id: item.url) {
            favicon = nil
            let image = await withCheckedContinuation { continuation in
                FaviconService.load(for: item.url) { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled else { return }
            favicon = image
        }
        .onReceive(NotificationCenter.default.publisher(for: .lemonFaviconDidUpdate)) { notification in
            guard notification.object as? String == FaviconService.originKey(for: item.url),
                  let image = notification.userInfo?["image"] as? NSImage else { return }
            favicon = image
        }
    }
}

private struct ShortcutEditorDraft: Identifiable {
    let id = UUID()
    var shortcutID: UUID?
    var title = ""
    var address = ""
    init(shortcut: StartPageShortcut? = nil) {
        shortcutID = shortcut?.id
        title = shortcut?.title ?? ""
        address = shortcut?.url.absoluteString ?? ""
    }
}

private struct StartPageShortcutEditor: View {
    @ObservedObject var store: StartPageStore
    let draft: ShortcutEditorDraft
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var address: String
    @State private var error: String?
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case title, address }

    init(store: StartPageStore, draft: ShortcutEditorDraft) {
        self.store = store
        self.draft = draft
        _title = State(initialValue: draft.title)
        _address = State(initialValue: draft.address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.shortcutID == nil ? "添加网页" : "编辑网页").font(.title3.weight(.semibold))
            Form {
                TextField("名称", text: $title).focused($focusedField, equals: .title)
                    .accessibilityIdentifier("start-page-web-title")
                TextField("网址", text: $address).focused($focusedField, equals: .address)
                    .accessibilityIdentifier("start-page-web-address")
            }
            .textFieldStyle(.roundedBorder)
            Text("未填写名称时使用网站域名；未写协议的网址默认使用 HTTPS。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try store.saveShortcut(id: draft.shortcutID, title: title, address: address)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { focusedField = .address }
    }
}
