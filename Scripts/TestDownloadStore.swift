import Foundation

@main
struct TestDownloadStore {
    static func main() throws {
        var existing = Set<String>()
        let folder = URL(fileURLWithPath: "/tmp")
        let first = DownloadFileNaming.uniqueURL(in: folder, preferredName: "report.pdf") { path in
            existing.contains(path)
        }
        existing.insert(first.path)
        let second = DownloadFileNaming.uniqueURL(in: folder, preferredName: "report.pdf") { path in
            existing.contains(path)
        }
        precondition(first.lastPathComponent == "report.pdf")
        precondition(second.lastPathComponent == "report 1.pdf")
        let safe = DownloadFileNaming.uniqueURL(in: folder, preferredName: "../../outside.pdf") { _ in false }
        precondition(safe.deletingLastPathComponent() == folder)

        let item = DownloadItem(
            id: UUID(),
            filename: "report.pdf",
            fileURL: first,
            sourceURL: URL(string: "https://example.com/report.pdf"),
            state: .completed,
            receivedBytes: 1024,
            expectedBytes: 1024,
            errorDescription: nil,
            createdAt: Date()
        )
        let data = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([DownloadItem].self, from: data)
        precondition(decoded.count == 1)
        precondition(decoded[0].filename == "report.pdf")
        precondition(decoded[0].state == .completed)
        precondition(decoded[0].progress == 1)

        let failed = DownloadItem(
            id: UUID(),
            filename: "video.mp4",
            fileURL: folder.appendingPathComponent("video.mp4"),
            sourceURL: URL(string: "https://example.com/video.mp4"),
            state: .failed,
            receivedBytes: 20,
            expectedBytes: 100,
            errorDescription: "网络中断",
            createdAt: Date()
        )
        precondition(failed.progress == 0.2)
        precondition(failed.statusText == "网络中断")

        print("download-store-tests=passed")
    }
}
