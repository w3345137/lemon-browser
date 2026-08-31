import Foundation

@main
enum TestDownloadIntegrity {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemon-download-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appendingPathComponent("fixture.bin")
        let bytes = Data(repeating: 0x5A, count: 4096)
        try bytes.write(to: file, options: .atomic)
        let validatedBytes = try DownloadFileIntegrity.validate(fileURL: file, expectedBytes: 4096)
        precondition(validatedBytes == 4096)

        do {
            _ = try DownloadFileIntegrity.validate(fileURL: file, expectedBytes: 8192)
            preconditionFailure("尺寸不符应抛出错误")
        } catch let error as DownloadFileIntegrity.ValidationError {
            precondition(error == .sizeMismatch(expected: 8192, actual: 4096))
        }

        try FileManager.default.removeItem(at: file)
        do {
            _ = try DownloadFileIntegrity.validate(fileURL: file, expectedBytes: 4096)
            preconditionFailure("文件缺失应抛出错误")
        } catch let error as DownloadFileIntegrity.ValidationError {
            precondition(error == .missing)
        }

        let removable = folder.appendingPathComponent("delete-me.bin")
        try bytes.write(to: removable, options: .atomic)
        try DownloadFileDeletion.removeIfPresent(fileURL: removable)
        precondition(!FileManager.default.fileExists(atPath: removable.path))
        try DownloadFileDeletion.removeIfPresent(fileURL: removable)

        print("download-integrity-tests=passed")
    }
}
