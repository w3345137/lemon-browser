import AppKit
import Foundation
import UserNotifications
import WebKit

@MainActor
final class DownloadStore: NSObject, ObservableObject {
    static let shared = DownloadStore(persistent: true)

    @Published private(set) var items: [DownloadItem] = []

    private let persistent: Bool
    private let storageURL: URL
    private let resumeFolder: URL
    private var activeDownloads: [UUID: WKDownload] = [:]
    private var downloadIDs: [ObjectIdentifier: UUID] = [:]
    private var progressObservers: [UUID: NSKeyValueObservation] = [:]
    private var resumeHost: WKWebView?
    private var didRequestNotification = false

    init(persistent: Bool) {
        self.persistent = persistent
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Lumen", isDirectory: true) // Legacy namespace preserves existing profiles.
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        storageURL = folder.appendingPathComponent("downloads.json")
        resumeFolder = folder
        super.init()
        if persistent {
            load()
        }
    }

    var hasActiveDownloads: Bool {
        items.contains { $0.state == .downloading }
    }

    var activeProgress: Double? {
        let active = items.filter { $0.state == .downloading }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(Int64(0)) { $0 + max(0, $1.expectedBytes) }
        guard total > 0 else { return nil }
        let received = active.reduce(Int64(0)) { partial, item in
            partial + min(max(0, item.receivedBytes), max(0, item.expectedBytes))
        }
        return min(1, max(0, Double(received) / Double(total)))
    }

    func retry(_ item: DownloadItem) {
        guard item.state == .failed || item.state == .paused else { return }
        let host = resumeWebView()
        if let resumeData = resumeData(for: item.id) {
            host.resumeDownload(fromResumeData: resumeData) { [weak self] download in
                Task { @MainActor in
                    self?.attach(download, to: item.id, sourceURL: item.sourceURL)
                    self?.update(item.id) {
                        $0.state = .downloading
                        $0.errorDescription = nil
                    }
                }
            }
            return
        }
        guard let sourceURL = item.sourceURL else {
            update(item.id) {
                $0.state = .failed
                $0.errorDescription = "没有可恢复的下载数据。"
            }
            return
        }
        host.startDownload(using: URLRequest(url: sourceURL)) { [weak self] download in
            Task { @MainActor in
                self?.attach(download, to: item.id, sourceURL: sourceURL)
                self?.update(item.id) {
                    $0.state = .downloading
                    $0.errorDescription = nil
                }
            }
        }
    }

    func pause(_ item: DownloadItem) {
        guard let download = activeDownloads[item.id] else { return }
        download.cancel { [weak self] resumeData in
            Task { @MainActor in
                self?.storeResumeData(resumeData, for: item.id)
                self?.detach(item.id)
                self?.update(item.id) {
                    $0.state = .paused
                }
            }
        }
    }

    func reveal(_ item: DownloadItem) {
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            markMissing(item)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }

    func open(_ item: DownloadItem) {
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            markMissing(item)
            return
        }
        NSWorkspace.shared.open(item.fileURL)
    }

    func delete(_ item: DownloadItem) throws {
        if let download = activeDownloads[item.id] {
            download.cancel { _ in }
        }
        detach(item.id)
        removeResumeData(for: item.id)
        try DownloadFileDeletion.removeIfPresent(fileURL: item.fileURL)
        items.removeAll { $0.id == item.id }
        persist()
    }

    private func attach(_ download: WKDownload, to id: UUID, sourceURL: URL?) {
        download.delegate = self
        activeDownloads[id] = download
        downloadIDs[ObjectIdentifier(download)] = id
        observe(download, id: id)
        if let sourceURL {
            update(id) { $0.sourceURL = sourceURL }
        }
    }

    private func begin(_ download: WKDownload, response: URLResponse, suggestedFilename: String) -> URL {
        // 沙盒返回的 Downloads URL 可能是容器内符号链接。解析到真实用户目录后交给
        // WKDownload，避免完成记录指向已消失的容器中转路径。
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .resolvingSymlinksInPath()
        let destination = DownloadFileNaming.uniqueURL(in: folder, preferredName: suggestedFilename)
        let existingID = downloadIDs[ObjectIdentifier(download)]
        let id = existingID ?? UUID()
        let item = DownloadItem(
            id: id,
            filename: destination.lastPathComponent,
            fileURL: destination,
            sourceURL: download.originalRequest?.url ?? response.url,
            state: .downloading,
            receivedBytes: 0,
            expectedBytes: response.expectedContentLength > 0 ? response.expectedContentLength : 0,
            errorDescription: nil,
            createdAt: Date()
        )
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
        attach(download, to: id, sourceURL: item.sourceURL)
        persist()
        requestNotificationPermissionIfNeeded()
        return destination
    }

    private func observe(_ download: WKDownload, id: UUID) {
        progressObservers[id] = download.progress.observe(\.completedUnitCount, options: [.new, .initial]) { [weak self] progress, _ in
            Task { @MainActor in
                self?.update(id) {
                    $0.receivedBytes = progress.completedUnitCount
                    if progress.totalUnitCount > 0 {
                        $0.expectedBytes = progress.totalUnitCount
                    }
                }
            }
        }
    }

    private func finish(_ download: WKDownload) {
        guard let id = downloadIDs[ObjectIdentifier(download)] else { return }
        detach(id)
        removeResumeData(for: id)
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            let actualBytes = try DownloadFileIntegrity.validate(
                fileURL: item.fileURL,
                expectedBytes: item.expectedBytes
            )
            update(id) {
                $0.state = .completed
                $0.receivedBytes = actualBytes
                if $0.expectedBytes <= 0 {
                    $0.expectedBytes = actualBytes
                }
                $0.errorDescription = nil
            }
            persist()
            notifyFinished(id: id)
        } catch {
            // 尺寸不符的成品没有可用续传数据，保留会误导用户，直接清理后允许重试。
            if let integrityError = error as? DownloadFileIntegrity.ValidationError,
               case .sizeMismatch = integrityError {
                try? FileManager.default.removeItem(at: item.fileURL)
            }
            update(id) {
                $0.state = .failed
                if let integrityError = error as? DownloadFileIntegrity.ValidationError,
                   case .sizeMismatch = integrityError {
                    $0.errorDescription = "\(error.localizedDescription) 已移除不完整文件。"
                } else {
                    $0.errorDescription = error.localizedDescription
                }
            }
            persist()
        }
    }

    private func fail(_ download: WKDownload, error: Error, resumeData: Data?) {
        guard let id = downloadIDs[ObjectIdentifier(download)] else { return }
        storeResumeData(resumeData, for: id)
        detach(id)
        update(id) {
            $0.state = resumeData == nil ? .failed : .paused
            $0.errorDescription = error.localizedDescription
        }
        persist()
    }

    private func update(_ id: UUID, mutate: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }

    private func markMissing(_ item: DownloadItem) {
        update(item.id) {
            $0.state = .failed
            $0.errorDescription = DownloadFileIntegrity.ValidationError.missing.localizedDescription
        }
        persist()
    }

    private func detach(_ id: UUID) {
        if let download = activeDownloads.removeValue(forKey: id) {
            downloadIDs.removeValue(forKey: ObjectIdentifier(download))
        }
        progressObservers[id] = nil
        maybeReleaseResumeHost()
    }

    private func resumeWebView() -> WKWebView {
        if let resumeHost { return resumeHost }
        let view = WebKitFactory.makeWebView(isPrivate: false)
        resumeHost = view
        return view
    }

    /// 隐藏宿主 WebView 只在恢复/重试下载时需要；没有任何进行中的下载时
    /// 及时释放，避免它连带的 WebContent 进程常驻。
    private func maybeReleaseResumeHost() {
        guard activeDownloads.isEmpty else { return }
        resumeHost = nil
    }

    private func resumeDataURL(for id: UUID) -> URL {
        resumeFolder.appendingPathComponent("\(id.uuidString).resume")
    }

    private func resumeData(for id: UUID) -> Data? {
        try? Data(contentsOf: resumeDataURL(for: id))
    }

    private func storeResumeData(_ data: Data?, for id: UUID) {
        let url = resumeDataURL(for: id)
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func removeResumeData(for id: UUID) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: id))
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = decoded.map { item in
            var item = item
            if item.state == .downloading {
                item.state = resumeData(for: item.id) == nil ? .failed : .paused
                item.errorDescription = item.state == .failed ? "浏览器退出时下载中断。" : item.errorDescription
            } else if item.state == .completed {
                do {
                    item.receivedBytes = try DownloadFileIntegrity.validate(
                        fileURL: item.fileURL,
                        expectedBytes: item.expectedBytes
                    )
                } catch {
                    item.state = .failed
                    item.errorDescription = error.localizedDescription
                }
            }
            return item
        }
        persist()
    }

    private func persist() {
        guard persistent else { return }
        let snapshot = Array(items.prefix(80))
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        guard persistent, !didRequestNotification else { return }
        didRequestNotification = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyFinished(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let content = UNMutableNotificationContent()
        content.title = "下载完成"
        content.body = item.filename
        let request = UNNotificationRequest(
            identifier: "download.\(id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

extension DownloadStore: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        begin(download, response: response, suggestedFilename: suggestedFilename)
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        fail(download, error: error, resumeData: resumeData)
    }
}
