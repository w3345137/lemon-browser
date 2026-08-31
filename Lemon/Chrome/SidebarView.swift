import SwiftUI

struct SidebarView: View {
    @ObservedObject var state: BrowserWindowState
    @ObservedObject private var bookmarks: BookmarkStore
    @ObservedObject private var history: HistoryStore
    @ObservedObject private var downloads: DownloadStore

    init(state: BrowserWindowState) {
        self.state = state
        _bookmarks = ObservedObject(wrappedValue: state.bookmarks)
        _history = ObservedObject(wrappedValue: state.history)
        _downloads = ObservedObject(wrappedValue: state.downloads)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.sidebarTab) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider()

            switch state.sidebarTab {
            case .bookmarks:
                bookmarkList
            case .history:
                historyList
            case .downloads:
                downloadList
            }
        }
        .background(.ultraThinMaterial)
    }

    private var bookmarkList: some View {
        List {
            Section("收藏") {
                ForEach(bookmarks.favorites) { item in
                    sidebarRow(title: item.title, url: item.url)
                }
            }
            Section("书签栏") {
                ForEach(bookmarks.barItems) { item in
                    if item.isFolder {
                        Label(item.title, systemImage: "folder.fill")
                            .foregroundStyle(.secondary)
                            .contextMenu {
                                Button("编辑…") { state.editBookmark(item) }
                                Divider()
                                Button("移除", role: .destructive) { bookmarks.remove(item.id) }
                            }
                    } else {
                        sidebarRow(title: item.title, url: item.url)
                            .contextMenu {
                                Button("编辑…") { state.editBookmark(item) }
                                Divider()
                                Button("移除", role: .destructive) { bookmarks.remove(item.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var historyList: some View {
        List {
            ForEach(history.grouped, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { entry in
                        sidebarRow(title: entry.title, url: entry.url)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if history.entries.isEmpty {
                Text(state.isPrivate ? "无痕窗口不保留历史记录" : "暂无历史记录")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    private var downloadList: some View {
        List(downloads.items) { item in
            Button {
                if item.state == .completed {
                    downloads.reveal(item)
                } else if item.state == .failed || item.state == .paused {
                    downloads.retry(item)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(item.filename, systemImage: "arrow.down.circle")
                    Text(item.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if item.state == .downloading {
                        ProgressView(value: item.progress)
                    }
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if item.state == .completed {
                    Button("打开") { downloads.open(item) }
                }
                if item.state == .paused || item.state == .failed {
                    Button("继续下载") { downloads.retry(item) }
                }
                Button("在 Finder 中显示") { downloads.reveal(item) }
                Divider()
                Button("删除下载文件…", role: .destructive) {
                    confirmAndDeleteDownload(item, from: downloads)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if downloads.items.isEmpty {
                Text("暂无下载")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    private func sidebarRow(title: String, url: URL) -> some View {
        Button {
            state.openInNewTab(url)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(URLInput.simplifiedHost(from: url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
