import SwiftUI
import WebKit

@MainActor
final class WebsiteDataManager: ObservableObject {
    @Published private(set) var records: [WKWebsiteDataRecord] = []
    @Published private(set) var isLoading = false

    func refresh() {
        isLoading = true
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            Task { @MainActor in
                self?.records = records.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                self?.isLoading = false
            }
        }
    }

    func remove(record: WKWebsiteDataRecord, completion: @escaping () -> Void = {}) {
        WKWebsiteDataStore.default().removeData(
            ofTypes: record.dataTypes,
            for: [record]
        ) { [weak self] in
            Task { @MainActor in
                self?.refresh()
                completion()
            }
        }
    }

    func removeAll(completion: @escaping () -> Void = {}) {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { [weak self] in
            Task { @MainActor in
                self?.refresh()
                completion()
            }
        }
    }
}

struct WebsiteDataSettingsView: View {
    @StateObject private var dataManager = WebsiteDataManager()
    @ObservedObject private var permissions = SitePermissionStore.shared
    @State private var query = ""
    @State private var selectedHost: String?
    @State private var confirmHostRemoval: String?
    @State private var confirmingRemoveAll = false

    private var hosts: [String] {
        let webKitHosts = dataManager.records.map(\.displayName)
        let merged = Array(Set(webKitHosts + permissions.configuredHosts)).sorted()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? merged : merged.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                siteList
                    .frame(minWidth: 220, idealWidth: 245, maxWidth: 300)
                    .frame(maxHeight: .infinity)
                detail
                    .frame(minWidth: 390)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { dataManager.refresh() }
        .confirmationDialog(
            "清除此网站的数据与权限？",
            isPresented: Binding(
                get: { confirmHostRemoval != nil },
                set: { if !$0 { confirmHostRemoval = nil } }
            )
        ) {
            Button("清除", role: .destructive) {
                if let host = confirmHostRemoval { remove(host: host) }
                confirmHostRemoval = nil
            }
            Button("取消", role: .cancel) { confirmHostRemoval = nil }
        } message: {
            Text("该网站可能会退出登录，并在下次访问时重新请求权限。")
        }
        .confirmationDialog("清除全部网站数据与权限？", isPresented: $confirmingRemoveAll) {
            Button("全部清除", role: .destructive) {
                dataManager.removeAll()
                permissions.resetAll()
                selectedHost = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有网站会退出登录，缓存、本地存储和自定义权限也会被移除。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("网站数据与权限")
                    .font(.system(size: 20, weight: .semibold))
                Text("查看登录数据、缓存和网站权限")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索网站", text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button { dataManager.refresh() } label: {
                if dataManager.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("重新读取网站数据")
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    private var siteList: some View {
        VStack(spacing: 0) {
            List(hosts, id: \.self, selection: $selectedHost) { host in
                HStack(spacing: 9) {
                    Image(systemName: permissions.hasCustomPermissions(for: host) ? "globe.badge.chevron.backward" : "globe")
                        .foregroundStyle(permissions.hasCustomPermissions(for: host) ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host).lineLimit(1)
                        Text(summary(for: host))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .tag(host)
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Text("\(hosts.count) 个网站")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部清除…", role: .destructive) { confirmingRemoveAll = true }
                    .buttonStyle(.borderless)
                    .disabled(hosts.isEmpty)
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedHost {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 25))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedHost).font(.title3.weight(.semibold))
                            Text("网站数据和单独设置的权限")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("已存储的数据") {
                        VStack(alignment: .leading, spacing: 10) {
                            let labels = dataLabels(for: selectedHost)
                            if labels.isEmpty {
                                Text("没有检测到 WebKit 网站数据")
                                    .foregroundStyle(.secondary)
                            } else {
                                FlowLabels(labels: labels)
                            }
                            Text("清除 Cookie 或本地存储后，此网站通常需要重新登录。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }

                    GroupBox("权限") {
                        VStack(spacing: 0) {
                            ForEach(SitePermissionKind.allCases) { kind in
                                HStack {
                                    Label(kind.title, systemImage: kind.symbol)
                                    Spacer()
                                    Picker("", selection: permissionBinding(host: selectedHost, kind: kind)) {
                                        ForEach(SitePermissionChoice.allCases) { choice in
                                            Text(choice.title).tag(choice)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 110)
                                }
                                .frame(height: 38)
                                if kind != SitePermissionKind.allCases.last { Divider() }
                            }
                            ForEach(permissions.externalApplicationSchemes(for: selectedHost), id: \.self) { scheme in
                                Divider()
                                HStack {
                                    Label("打开 \(scheme) 链接", systemImage: "arrow.up.forward.app")
                                    Spacer()
                                    Picker(
                                        "",
                                        selection: Binding(
                                            get: {
                                                permissions.externalApplicationChoice(
                                                    for: selectedHost,
                                                    scheme: scheme
                                                )
                                            },
                                            set: {
                                                permissions.setExternalApplicationChoice(
                                                    $0,
                                                    for: selectedHost,
                                                    scheme: scheme
                                                )
                                            }
                                        )
                                    ) {
                                        ForEach(SitePermissionChoice.allCases) { choice in
                                            Text(choice.title).tag(choice)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 110)
                                }
                                .frame(height: 38)
                            }
                        }
                        .padding(.horizontal, 8)
                    }

                    HStack {
                        Button("恢复默认权限") { permissions.reset(host: selectedHost) }
                            .disabled(!permissions.hasCustomPermissions(for: selectedHost))
                        Spacer()
                        Button("清除数据与权限…", role: .destructive) {
                            confirmHostRemoval = selectedHost
                        }
                    }
                }
                .padding(22)
            }
        } else {
            ContentUnavailableView(
                "选择一个网站",
                systemImage: "lock.shield",
                description: Text("可查看并调整此网站的数据和权限。")
            )
        }
    }

    private func record(for host: String) -> WKWebsiteDataRecord? {
        dataManager.records.first(where: { $0.displayName == host })
    }

    private func summary(for host: String) -> String {
        var parts = dataLabels(for: host)
        if permissions.hasCustomPermissions(for: host) { parts.append("自定义权限") }
        return parts.isEmpty ? "仅权限记录" : parts.prefix(3).joined(separator: "、")
    }

    private func dataLabels(for host: String) -> [String] {
        guard let types = record(for: host)?.dataTypes else { return [] }
        let mappings: [(String, String)] = [
            (WKWebsiteDataTypeCookies, "Cookie"),
            (WKWebsiteDataTypeDiskCache, "磁盘缓存"),
            (WKWebsiteDataTypeMemoryCache, "内存缓存"),
            (WKWebsiteDataTypeLocalStorage, "本地存储"),
            (WKWebsiteDataTypeSessionStorage, "会话存储"),
            (WKWebsiteDataTypeIndexedDBDatabases, "IndexedDB"),
            (WKWebsiteDataTypeServiceWorkerRegistrations, "Service Worker"),
            (WKWebsiteDataTypeWebSQLDatabases, "WebSQL")
        ]
        return mappings.compactMap { types.contains($0.0) ? $0.1 : nil }
    }

    private func permissionBinding(host: String, kind: SitePermissionKind) -> Binding<SitePermissionChoice> {
        Binding(
            get: { permissions.choice(for: host, kind: kind) },
            set: { permissions.set($0, for: host, kind: kind) }
        )
    }

    private func remove(host: String) {
        permissions.reset(host: host)
        if let record = record(for: host) {
            dataManager.remove(record: record)
        }
        if selectedHost == host { selectedHost = nil }
    }
}

private struct FlowLabels: View {
    let labels: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
    }
}
