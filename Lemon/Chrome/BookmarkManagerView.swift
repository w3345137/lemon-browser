import AppKit
import SwiftUI

struct BookmarkManagerView: View {
    @ObservedObject private var store = BookmarkStore.shared
    @State private var selectedFolderID: BookmarkItem.ID?
    @State private var selectedItemID: BookmarkItem.ID?
    @State private var query = ""
    @State private var editor: BookmarkEditorState?
    @State private var pendingDeletion: BookmarkItem?

    private var displayedItems: [BookmarkItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.children(of: selectedFolderID) }
        return store.allItems.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || (!$0.isFolder && $0.url.absoluteString.localizedCaseInsensitiveContains(trimmed))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                content
                    .frame(minWidth: 540)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editor) { state in
            BookmarkEditorSheet(state: state) { title, rawURL in
                saveEditor(state, title: title, rawURL: rawURL)
            }
        }
        .confirmationDialog(
            "移除书签？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("移除", role: .destructive) {
                if let item = pendingDeletion {
                    store.remove(item.id)
                    selectedItemID = nil
                }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let pendingDeletion {
                Text(pendingDeletion.isFolder
                     ? "文件夹“\(pendingDeletion.title)”及其中内容会从书签中移除。"
                     : "“\(pendingDeletion.title)”会从书签中移除。")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("书签管理器")
                    .font(.system(size: 20, weight: .semibold))
                Text("整理、编辑和移动书签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索书签", text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 210)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Menu {
                Button("新建书签…") {
                    editor = .newBookmark(parentID: selectedFolderID)
                }
                Button("新建文件夹…") {
                    editor = .newFolder(parentID: selectedFolderID)
                }
            } label: {
                Label("添加", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    private var sidebar: some View {
        List(selection: $selectedFolderID) {
            Label("书签栏", systemImage: "rectangle.topthird.inset.filled")
                .tag(nil as BookmarkItem.ID?)
            OutlineGroup(store.barItems.filter(\.isFolder), children: \.folderChildren) { folder in
                Label(folder.title.isEmpty ? "未命名文件夹" : folder.title, systemImage: "folder")
                    .tag(folder.id as BookmarkItem.ID?)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("共 \(store.allURLItems.count) 个书签")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Text(query.isEmpty ? currentLocationTitle : "搜索结果")
                    .font(.headline)
                Spacer()
                Text("\(displayedItems.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()

            if displayedItems.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "此文件夹为空" : "没有匹配的书签",
                    systemImage: query.isEmpty ? "folder" : "magnifyingglass",
                    description: Text(query.isEmpty ? "可从上方添加书签或文件夹。" : "请尝试其他关键词。")
                )
            } else {
                List(displayedItems, selection: $selectedItemID) { item in
                    BookmarkManagerRow(item: item, location: store.path(for: item.id).joined(separator: " / "))
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { activate(item) }
                        .contextMenu { itemMenu(item) }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: BookmarkItem) -> some View {
        Button(item.isFolder ? "打开文件夹" : "在新标签页中打开") { activate(item) }
        Button("编辑…") { editor = .edit(item, parentID: store.parentFolderID(of: item.id)) }
        Menu("移动到") {
            Button("书签栏") { _ = store.move(item.id, toFolder: nil, before: nil) }
                .disabled(store.parentFolderID(of: item.id) == nil)
            Divider()
            ForEach(store.allFolders.filter { $0.id != item.id && !itemContains(item, id: $0.id) }) { folder in
                Button(folder.title.isEmpty ? "未命名文件夹" : folder.title) {
                    _ = store.move(item.id, toFolder: folder.id, before: nil)
                }
            }
        }
        Divider()
        Button("移除", role: .destructive) { pendingDeletion = item }
    }

    private var currentLocationTitle: String {
        guard let selectedFolderID, let folder = store.item(with: selectedFolderID) else { return "书签栏" }
        return folder.title.isEmpty ? "未命名文件夹" : folder.title
    }

    private func activate(_ item: BookmarkItem) {
        if item.isFolder {
            selectedFolderID = item.id
            query = ""
        } else {
            IncomingBrowserURL.deliver(item.url)
        }
    }

    private func itemContains(_ item: BookmarkItem, id: BookmarkItem.ID) -> Bool {
        item.children.contains { $0.id == id || itemContains($0, id: id) }
    }

    private func saveEditor(_ state: BookmarkEditorState, title: String, rawURL: String) {
        switch state.mode {
        case .newFolder:
            _ = store.addFolder(named: title, in: state.parentID)
        case .newBookmark:
            guard let url = normalizedURL(rawURL) else { return }
            _ = store.addBookmark(title: title, url: url, to: state.parentID)
        case .edit:
            guard let itemID = state.itemID, let item = store.item(with: itemID) else { return }
            store.update(itemID, title: title, url: item.isFolder ? nil : normalizedURL(rawURL))
        }
    }

    private func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URLInput.destination(from: trimmed)
    }
}

private struct BookmarkManagerRow: View {
    let item: BookmarkItem
    let location: String
    @State private var favicon: NSImage?

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if item.isFolder {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color(nsColor: .systemYellow))
                } else if let favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? (item.isFolder ? "未命名文件夹" : item.url.host ?? item.url.absoluteString) : item.title)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !item.isFolder {
                        Text(item.url.absoluteString)
                            .lineLimit(1)
                    }
                    if !location.isEmpty {
                        Text(location)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if item.isFolder {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 38)
        .task(id: item.url) {
            guard !item.isFolder else { return }
            FaviconService.load(for: item.url) { favicon = $0 }
        }
    }
}

private struct BookmarkEditorState: Identifiable {
    enum Mode: Equatable { case newBookmark, newFolder, edit }
    let id = UUID()
    let mode: Mode
    let itemID: BookmarkItem.ID?
    let parentID: BookmarkItem.ID?
    let initialTitle: String
    let initialURL: String

    static func newBookmark(parentID: BookmarkItem.ID?) -> Self {
        .init(mode: .newBookmark, itemID: nil, parentID: parentID, initialTitle: "", initialURL: "")
    }

    static func newFolder(parentID: BookmarkItem.ID?) -> Self {
        .init(mode: .newFolder, itemID: nil, parentID: parentID, initialTitle: "", initialURL: "")
    }

    static func edit(_ item: BookmarkItem, parentID: BookmarkItem.ID?) -> Self {
        .init(
            mode: .edit,
            itemID: item.id,
            parentID: parentID,
            initialTitle: item.title,
            initialURL: item.isFolder ? "" : item.url.absoluteString
        )
    }
}

private struct BookmarkEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let state: BookmarkEditorState
    let onSave: (String, String) -> Void
    @State private var title: String
    @State private var url: String

    init(state: BookmarkEditorState, onSave: @escaping (String, String) -> Void) {
        self.state = state
        self.onSave = onSave
        _title = State(initialValue: state.initialTitle)
        _url = State(initialValue: state.initialURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(sheetTitle)
                .font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $title)
                if state.mode != .newFolder, !(state.mode == .edit && state.initialURL.isEmpty) {
                    TextField("网址", text: $url)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(title, url)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (state.mode == .newBookmark && url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(22)
        .frame(width: 430)
    }

    private var sheetTitle: String {
        switch state.mode {
        case .newBookmark: "新建书签"
        case .newFolder: "新建文件夹"
        case .edit: "编辑书签"
        }
    }
}

private extension BookmarkItem {
    var folderChildren: [BookmarkItem]? {
        let folders = children.filter(\.isFolder)
        return folders.isEmpty ? nil : folders
    }
}
