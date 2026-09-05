import AppKit
import WebKit

@main
struct TestDownloadLive {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let server = Process()
        let port = Int.random(in: 26000...48000)
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [root.appendingPathComponent("DownloadFixtureServer.py").path, String(port)]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(server.isRunning)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DownloadStore(persistent: false, downloadsFolder: folder)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let host = WKWebView(frame: .zero, configuration: config)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/download")!)
        let download = await host.startDownload(using: request)
        download.delegate = store
        for _ in 0..<30 {
            if !store.items.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let reserved = store.items.first!.fileURL
        try Data("user-created-file".utf8).write(to: reserved)
        for _ in 0..<200 {
            if store.items.first?.state == .completed || store.items.first?.state == .failed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let finished = store.items.first!
        precondition(finished.state == .completed, finished.statusText)
        precondition(finished.partialURL == nil)
        precondition(finished.fileURL != reserved, "Do not overwrite a file created while downloading")
        let sentinel = try String(contentsOf: reserved, encoding: .utf8)
        precondition(sentinel == "user-created-file")
        let data = try Data(contentsOf: finished.fileURL)
        precondition(data == Data(repeating: 0x4c, count: 64 * 1024 * 256))
        try await store.delete(finished)
        precondition(!FileManager.default.fileExists(atPath: finished.fileURL.path))
        let cancelled = await host.startDownload(using: request)
        cancelled.delegate = store
        for _ in 0..<30 {
            if store.items.first?.receivedBytes ?? 0 > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let partial = store.items.first!
        precondition(partial.partialURL != nil)
        precondition(!FileManager.default.fileExists(atPath: partial.fileURL.path), "No unfinished final file")
        try await store.delete(partial)
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(store.items.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: partial.partialURL!.path))
        let pausable = await host.startDownload(using: request)
        pausable.delegate = store
        for _ in 0..<30 {
            if store.items.first?.receivedBytes ?? 0 > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        store.pause(store.items.first!)
        for _ in 0..<30 {
            if store.items.first?.state != .pausing { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let paused = store.items.first!
        precondition(paused.state == .paused && store.canResume(paused), paused.statusText)
        store.retry(paused)
        store.retry(paused) // stale UI snapshot must not launch a duplicate retry
        for _ in 0..<200 {
            if store.items.first?.state == .completed || store.items.first?.state == .failed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let resumed = store.items.first!
        precondition(store.items.count == 1)
        precondition(resumed.state == .completed, resumed.statusText)
        let resumedData = try Data(contentsOf: resumed.fileURL)
        precondition(resumedData == Data(repeating: 0x4c, count: 64 * 1024 * 256))
        try await store.delete(resumed)
        print("download-live-tests=passed")
    }
}
