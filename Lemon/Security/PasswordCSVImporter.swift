import Foundation

struct PasswordImportResult {
    let imported: Int
    let skipped: Int
}

enum PasswordCSVImporterError: LocalizedError {
    case unreadable
    case missingColumns

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "无法读取密码 CSV 文件。"
        case .missingColumns:
            return "CSV 中没有找到网址、用户名和密码列。请使用 360 浏览器的密码导出文件。"
        }
    }
}

@MainActor
enum PasswordCSVImporter {
    static func importFile(at url: URL, into store: CredentialStore) throws -> PasswordImportResult {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw PasswordCSVImporterError.unreadable
        }

        let rows = parseCSV(text)
        guard let rawHeader = rows.first else { throw PasswordCSVImporterError.missingColumns }
        let header = rawHeader.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{feff}", with: "")
                .lowercased()
        }

        func index(_ names: [String]) -> Int? {
            names.compactMap { header.firstIndex(of: $0) }.first
        }

        guard let urlIndex = index(["url", "origin", "website", "网址"]),
              let usernameIndex = index(["username", "username_value", "用户名", "账号"]),
              let passwordIndex = index(["password", "password_value", "密码"]) else {
            throw PasswordCSVImporterError.missingColumns
        }

        var imported = 0
        var skipped = 0
        let requiredIndex = max(urlIndex, usernameIndex, passwordIndex)

        for row in rows.dropFirst() {
            guard row.indices.contains(requiredIndex) else {
                skipped += 1
                continue
            }
            let rawURL = row[urlIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let username = row[usernameIndex]
            let password = row[passwordIndex]
            guard let scope = CredentialStore.normalizedScope(rawURL),
                  !password.isEmpty else {
                skipped += 1
                continue
            }
            try store.save(scope: scope, username: username, password: password)
            imported += 1
        }

        return PasswordImportResult(imported: imported, skipped: skipped)
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    quoted = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                case "\r":
                    break
                default:
                    field.append(character)
                }
            }
            index = text.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
