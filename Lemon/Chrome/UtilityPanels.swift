import AppKit
import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var state: BrowserWindowState
    @ObservedObject private var history: HistoryStore

    init(state: BrowserWindowState) {
        self.state = state
        _history = ObservedObject(wrappedValue: state.history)
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("历史记录", systemImage: "clock.arrow.circlepath") {
                Button("清除") { history.clear() }
                    .buttonStyle(.borderless)
                    .disabled(history.entries.isEmpty)
            }
            Divider()
            if history.entries.isEmpty {
                emptyState("暂无历史记录", systemImage: "clock")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(history.grouped, id: \.0) { group in
                            Text(group.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, 12)
                                .padding(.bottom, 5)
                            ForEach(group.1) { entry in
                                Button { state.openInNewTab(entry.url) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "clock")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.title)
                                                .font(.system(size: 12.5))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(URLInput.simplifiedHost(from: entry.url))
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text(entry.visitedAt, style: .time)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 48)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 370, height: 430)
        .background(.regularMaterial)
    }
}

struct DownloadsPanel: View {
    @ObservedObject var state: BrowserWindowState
    @ObservedObject private var downloads: DownloadStore

    init(state: BrowserWindowState) {
        self.state = state
        _downloads = ObservedObject(wrappedValue: state.downloads)
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("下载", systemImage: "arrow.down.to.line") {
                Button("打开下载文件夹") {
                    if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                        NSWorkspace.shared.open(folder)
                    }
                }
                .buttonStyle(.borderless)
            }
            Divider()
            if downloads.items.isEmpty {
                emptyState("暂无下载", systemImage: "arrow.down.circle")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(downloads.items) { item in
                            downloadRow(item)
                        }
                    }
                }
            }
        }
        .frame(width: 390, height: 360)
        .background(.regularMaterial)
    }

    private func downloadRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: downloadSymbol(item.state))
                .font(.system(size: 14))
                .foregroundStyle(item.state == .failed ? Color.orange : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                if item.state == .downloading {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                }
                Text(item.statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if item.state == .downloading {
                Button("暂停") { downloads.pause(item) }
                    .buttonStyle(.borderless)
            } else if item.state == .paused || item.state == .failed {
                Button("重试") { downloads.retry(item) }
                    .buttonStyle(.borderless)
            } else {
                Button("打开") { downloads.open(item) }
                    .buttonStyle(.borderless)
            }
            Button {
                downloads.reveal(item)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")

            Button {
                confirmAndDeleteDownload(item, from: downloads)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("删除下载记录和本地文件")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
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

    private func downloadSymbol(_ state: DownloadState) -> String {
        switch state {
        case .downloading: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}

@MainActor
func confirmAndDeleteDownload(_ item: DownloadItem, from downloads: DownloadStore) {
    let alert = NSAlert()
    alert.messageText = "删除下载文件？"
    alert.informativeText = "将同时删除“\(item.filename)”的下载记录、续传数据和本地文件。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "删除")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    do {
        try downloads.delete(item)
    } catch {
        let failure = NSAlert(error: error)
        failure.messageText = "无法删除下载文件"
        failure.runModal()
    }
}

private func panelHeader<Trailing: View>(
    _ title: String,
    systemImage: String,
    @ViewBuilder trailing: () -> Trailing
) -> some View {
    HStack(spacing: 8) {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
        Text(title)
            .font(.system(size: 15, weight: .semibold))
        Spacer()
        trailing()
    }
    .padding(.horizontal, 14)
    .frame(height: 46)
}

private func emptyState(_ title: String, systemImage: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: systemImage)
            .font(.system(size: 28, weight: .light))
            .foregroundStyle(.tertiary)
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
