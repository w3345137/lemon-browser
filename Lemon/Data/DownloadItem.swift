import Foundation

enum DownloadState: String, Codable {
    case downloading
    case paused
    case completed
    case failed
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id: UUID
    var filename: String
    var fileURL: URL
    var sourceURL: URL?
    var state: DownloadState
    var receivedBytes: Int64
    var expectedBytes: Int64
    var errorDescription: String?
    var createdAt: Date

    var progress: Double {
        guard expectedBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    var statusText: String {
        switch state {
        case .downloading:
            if expectedBytes > 0 {
                return "\(byteText(receivedBytes)) / \(byteText(expectedBytes))"
            }
            return receivedBytes > 0 ? byteText(receivedBytes) : "正在下载…"
        case .paused:
            return "已暂停"
        case .completed:
            return "已完成"
        case .failed:
            return errorDescription ?? "下载失败"
        }
    }

    private func byteText(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

enum DownloadFileNaming {
    static func uniqueURL(
        in folder: URL,
        preferredName: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        var candidate = folder.appendingPathComponent(preferredName)
        var index = 1
        let ns = preferredName as NSString
        while fileExists(candidate.path) {
            let suffix = ns.pathExtension.isEmpty ? "" : ".\(ns.pathExtension)"
            candidate = folder.appendingPathComponent("\(ns.deletingPathExtension) \(index)\(suffix)")
            index += 1
        }
        return candidate
    }
}

enum DownloadFileIntegrity {
    enum ValidationError: LocalizedError, Equatable {
        case missing
        case sizeMismatch(expected: Int64, actual: Int64)

        var errorDescription: String? {
            switch self {
            case .missing:
                return "下载文件未写入磁盘，请重试。"
            case let .sizeMismatch(expected, actual):
                return "下载文件不完整（应为 \(byteText(expected))，实际为 \(byteText(actual))），请重试。"
            }
        }

        private func byteText(_ value: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        }
    }

    static func validate(
        fileURL: URL,
        expectedBytes: Int64,
        fileManager: FileManager = .default
    ) throws -> Int64 {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ValidationError.missing
        }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if expectedBytes > 0, actualBytes != expectedBytes {
            throw ValidationError.sizeMismatch(expected: expectedBytes, actual: actualBytes)
        }
        return actualBytes
    }
}

enum DownloadFileDeletion {
    static func removeIfPresent(
        fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
