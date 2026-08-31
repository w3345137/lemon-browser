import AppKit
import SwiftUI

struct StartPageView: View {
    @ObservedObject var state: BrowserWindowState

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Spacer().frame(height: 12)
                    header
                    favorites
                    if !state.isPrivate {
                        recents
                    } else {
                        privateCard
                    }
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
            }
        }
    }

    private var background: some View {
        ZStack {
            if state.isPrivate {
                Color(red: 0.10, green: 0.10, blue: 0.12)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            LinearGradient(
                colors: state.isPrivate
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
            Text(state.isPrivate ? "无痕浏览" : "起始页")
                .font(.system(size: 30, weight: .semibold))
            Text(state.isPrivate ? "此窗口不会保存历史记录、搜索和自动填充信息。" : "地址栏和书签会在新标签页打开。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 28)
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("收藏")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 6), spacing: 18) {
                ForEach(state.bookmarks.favorites.prefix(12)) { item in
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
            Text("最近访问")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(state.history.entries.prefix(8)) { entry in
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
            if state.history.entries.isEmpty {
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
            Label("无痕窗口使用单独的 WebKit 数据容器", systemImage: "eye.slash")
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
        .onAppear {
            FaviconService.load(for: item.url) { favicon = $0 }
        }
    }
}
