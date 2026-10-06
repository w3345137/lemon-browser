import AppKit
import Foundation

/// Explicit network check for the legacy HTTP bookmark; separate from offline regression.
@main enum TestFaviconLive {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemon-favicon-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FaviconService.testCacheDirectory = directory
        let source = URL(string: "http://movie.douban.com/nowplaying/shenzhen/")!
        let icon: NSImage? = await withCheckedContinuation { continuation in
            FaviconService.load(for: source) { continuation.resume(returning: $0) }
        }
        print("douban-http-bookmark icon=\(icon != nil) size=\(icon?.size ?? .zero)")
        fflush(stdout)
        guard let icon, let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FaviconLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Legacy HTTP Douban bookmark has no favicon"])
        }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/douban-favicon-live.png")
        try png.write(to: output)
        print("favicon-live-tests=passed")
    }
}
