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
    private var pendingRetries = Set<UUID>()
    private let destinationFolder: URL

    init(persistent: Bool, downloadsFolder: URL? = nil) {
        self.persistent = persistent
        self.destinationFolder = downloadsFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.resolvingSymlinksInPath()
        let folder = persistent ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Lumen", isDirectory: true) // Legacy namespace preserves existing profiles.
            .appendingPathComponent("Downloads", isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("lemon-private-downloads-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        storageURL = folder.appendingPathComponent("downloads.json")
        resumeFolder = folder
        super.init()
        if persistent {
            load()
        }
    }

    var hasActiveDownloads: Bool {
        items.contains { [.starting, .downloading, .pausing, .verifying].contains($0.state) }
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

    func retry(_ item: DownloadItem, allowResume: Bool = true) {
        guard let item = items.first(where: { $0.id == item.id }),
              item.state == .failed || item.state == .paused,
              pendingRetries.insert(item.id).inserted else { return }
        let host = resumeWebView()
        update(item.id) { $0.state = .starting; $0.errorDescription = nil }
        persist()
        if allowResume, let resumeData = resumeData(for: item.id) {
            host.resumeDownload(fromResumeData: resumeData) { [weak self] download in
                Task { @MainActor in
                    guard let self, self.pendingRetries.remove(item.id) != nil,
                          self.items.contains(where: { $0.id == item.id }) else {
                        download.cancel { _ in }; return
                    }
                    self.attach(download, to: item.id, sourceURL: item.sourceURL)
                    self.update(item.id) {
                        $0.state = .downloading
                        $0.errorDescription = nil
                    }
                }
            }
            return
        }
        removeResumeData(for: item.id)
        guard let sourceURL = item.sourceURL,
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
              item.requestMethod == nil || item.requestMethod == "GET" else {
            pendingRetries.remove(item.id)
            update(item.id) {
                $0.state = .failed
                $0.errorDescription = "无法直接重新下载，请回到原网页再次点击下载。"
            }
            persist()
            maybeReleaseResumeHost()
            return
        }
        // A new request must not retain a previous attempt's partial destination.
        if let partial = item.partialURL { try? DownloadFileDeletion.removeIfPresent(fileURL: partial) }
        update(item.id) { $0.partialURL = nil; $0.receivedBytes = 0; $0.expectedBytes = 0 }
        host.startDownload(using: URLRequest(url: sourceURL)) { [weak self] download in
            Task { @MainActor in
                guard let self, self.pendingRetries.remove(item.id) != nil,
                      self.items.contains(where: { $0.id == item.id }) else {
                    download.cancel { _ in }; return
                }
                self.attach(download, to: item.id, sourceURL: sourceURL)
                self.update(item.id) {
                    $0.state = .downloading
                    $0.errorDescription = nil
                }
            }
        }
    }

    func pause(_ item: DownloadItem) {
        guard let download = activeDownloads[item.id],
              items.first(where: { $0.id == item.id })?.state == .downloading else { return }
        update(item.id) { $0.state = .pausing }
        persist()
        // Stop delegate/progress races before the asynchronous cancellation callback.
        detach(item.id)
        download.cancel { [weak self] resumeData in
            Task { @MainActor in
                guard self?.items.contains(where: { $0.id == item.id }) == true else { return }
                self?.storeResumeData(resumeData, for: item.id)
                self?.update(item.id) {
                    $0.state = resumeData == nil ? .failed : .paused
                    $0.errorDescription = resumeData == nil ? "此下载不支持续传，可重新下载。" : nil
                }
                self?.persist()
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
        guard item.state == .completed else { return }
        do {
            _ = try DownloadFileIntegrity.validate(fileURL: item.fileURL, expectedBytes: item.receivedBytes)
        } catch {
            update(item.id) { $0.state = .failed; $0.errorDescription = error.localizedDescription }
            persist()
            return
        }
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            markMissing(item)
            return
        }
        NSWorkspace.shared.open(item.fileURL)
    }

    func delete(_ item: DownloadItem) async throws {
        pendingRetries.remove(item.id)
        let download = activeDownloads[item.id]
        detach(item.id)
        update(item.id) { $0.state = .pausing }
        if let download {
            await withCheckedContinuation { continuation in
                download.cancel { _ in continuation.resume() }
            }
        }
        removeResumeData(for: item.id)
        do {
            if let partial = item.partialURL { try DownloadFileDeletion.removeIfPresent(fileURL: partial) }
            try DownloadFileDeletion.removeIfPresent(fileURL: item.fileURL)
        } catch {
            update(item.id) { $0.state = .failed; $0.errorDescription = "删除失败：\(error.localizedDescription)" }
            persist()
            throw error
        }
        items.removeAll { $0.id == item.id }
        persist()
    }

    func canResume(_ item: DownloadItem) -> Bool { resumeData(for: item.id) != nil }

    func prepareToQuit(completion: @escaping () -> Void) {
        pendingRetries.removeAll()
        let group = DispatchGroup()
        for (id, download) in activeDownloads {
            group.enter()
            detach(id)
            download.cancel { [weak self] data in
                Task { @MainActor in
                    self?.storeResumeData(data, for: id)
                    self?.update(id) {
                        $0.state = data == nil ? .failed : .paused
                        $0.errorDescription = data == nil ? "退出时下载中断，需重新下载。" : nil
                    }
                    self?.persist()
                    group.leave()
                }
            }
        }
        group.notify(queue: .main, execute: completion)
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
        let folder = destinationFolder
        let reserved = Set(items.map { $0.fileURL.path })
        let destination = DownloadFileNaming.uniqueURL(in: folder, preferredName: suggestedFilename) {
            reserved.contains($0) || FileManager.default.fileExists(atPath: $0)
        }
        let existingID = downloadIDs[ObjectIdentifier(download)]
        let id = existingID ?? UUID()
        let partial = folder.appendingPathComponent(".lemon-\(UUID().uuidString).download")
        let encoding = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Encoding")
        let validatesLength = encoding == nil || encoding?.lowercased() == "identity"
        var item = DownloadItem(
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
        item.partialURL = partial
        item.requestMethod = download.originalRequest?.httpMethod
        item.validatesLength = validatesLength
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
        attach(download, to: id, sourceURL: item.sourceURL)
        persist()
        requestNotificationPermissionIfNeeded()
        return partial
    }

    private func observe(_ download: WKDownload, id: UUID) {
        progressObservers[id] = download.progress.observe(\.completedUnitCount, options: [.new, .initial]) { [weak self] progress, _ in
            Task { @MainActor in
                guard self?.downloadIDs[ObjectIdentifier(download)] == id else { return }
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
        update(id) { $0.state = .verifying }
        do {
            let actualBytes = try DownloadFileIntegrity.validate(
                fileURL: item.partialURL ?? item.fileURL,
                expectedBytes: item.validatesLength == false ? 0 : item.expectedBytes
            )
            var destination = item.fileURL
            if let partial = item.partialURL {
                destination = DownloadFileNaming.uniqueURL(in: item.fileURL.deletingLastPathComponent(), preferredName: item.filename)
                try FileManager.default.moveItem(at: partial, to: destination)
            }
            update(id) {
                $0.state = .completed
                $0.fileURL = destination
                $0.filename = destination.lastPathComponent
                $0.partialURL = nil
                $0.receivedBytes = actualBytes
                $0.expectedBytes = actualBytes
                $0.errorDescription = nil
            }
            persist()
            notifyFinished(id: id)
        } catch {
            // 尺寸不符的成品没有可用续传数据，保留会误导用户，直接清理后允许重试。
            if let integrityError = error as? DownloadFileIntegrity.ValidationError,
               case .sizeMismatch = integrityError {
                try? FileManager.default.removeItem(at: item.partialURL ?? item.fileURL)
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
            $0.state = .failed
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
        let view = WebKitFactory.makeWebView(isPrivate: !persistent)
        resumeHost = view
        return view
    }

    /// 隐藏宿主 WebView 只在恢复/重试下载时需要；没有任何进行中的下载时
    /// 及时释放，避免它连带的 WebContent 进程常驻。
    private func maybeReleaseResumeHost() {
        guard activeDownloads.isEmpty, pendingRetries.isEmpty else { return }
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
            if [.downloading, .starting, .pausing, .verifying].contains(item.state) {
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
        let snapshot = items
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
        guard persistent else { return }
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
        let destination = begin(download, response: response, suggestedFilename: suggestedFilename)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400,
           let id = downloadIDs[ObjectIdentifier(download)] {
            detach(id)
            update(id) { $0.state = .failed; $0.errorDescription = "服务器返回 HTTP \(http.statusCode)，请回到网页检查登录或链接。" }
            persist()
            return nil
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        fail(download, error: error, resumeData: resumeData)
    }
}
