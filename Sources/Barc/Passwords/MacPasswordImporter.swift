// Added for Barc: one-time Apple Passwords CSV import, 2026-10-25.
import Foundation

/// Reads an export chosen by the user. Never reads Apple Passwords directly,
/// logs credentials, or creates a plaintext copy of the export.
enum MacPasswordImporter {
    static let maximumBytes = 20 * 1024 * 1024
    struct Parsed: Sendable {
        var credentials: [PasswordCredential] = []
        var skipped = 0
    }
    struct Summary: Sendable, Equatable {
        var imported = 0
        var existing = 0
        var skipped = 0
    }
    enum Failure: LocalizedError {
        case tooLarge, invalidCSV, missingColumns, privateProfile
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Choose a password export smaller than 20 MB."
            case .invalidCSV: return "This file is not a valid UTF-8 password CSV export. No passwords were imported."
            case .missingColumns: return "Choose the CSV exported by Apple Passwords. It must contain URL, Username and Password columns."
            case .privateProfile: return "Passwords cannot be imported into a private profile."
            }
        }
    }

    static func read(_ url: URL) throws -> Parsed {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Parsed {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw Failure.invalidCSV }
        if text.first == "\u{feff}" { text.removeFirst() }
        let rows = try csvRows(text)
        guard let header = rows.first else { throw Failure.missingColumns }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(names).count == names.count,
              let urlIndex = names.firstIndex(of: "url"),
              let userIndex = names.firstIndex(of: "username"),
              let passwordIndex = names.firstIndex(of: "password") else { throw Failure.missingColumns }
        var result = Parsed()
        for row in rows.dropFirst() {
            guard row.count == header.count else { throw Failure.invalidCSV }
            guard let url = URL(string: row[urlIndex]),
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty,
                  url.user == nil, url.password == nil,
                  !row[passwordIndex].isEmpty else { result.skipped += 1; continue }
            result.credentials.append(.init(host: host, username: row[userIndex], password: row[passwordIndex],
                scheme: scheme, port: KeychainPasswordStore.port(for: url)))
        }
        return result
    }

    /// Merge one batch in one encrypted-vault transaction. A repeated import
    /// preserves existing passwords, even if they have a different source path.
    static func merge(_ parsed: Parsed, identity: Space.Identity,
                      into entries: inout [WebsitePasswordVault.Entry]) throws -> Summary {
        guard !identity.isPrivate else { throw Failure.privateProfile }
        let scope = ProfileDataPaths.key(for: identity)
        var existing = entries.filter { $0.scope == scope }.map(\.credential)
        var summary = Summary(skipped: parsed.skipped)
        for credential in parsed.credentials {
            if existing.contains(where: {
                $0.host.lowercased() == credential.host && $0.username == credential.username && $0.port == credential.port
                    && ($0.scheme == nil || $0.scheme == credential.scheme)
            }) { summary.existing += 1; continue }
            var saved = credential
            saved.storagePath = KeychainPasswordStore.path(for: identity)
            entries.append(.init(scope: scope, credential: saved))
            existing.append(saved)
            summary.imported += 1
        }
        return summary
    }

    private static func csvRows(_ text: String) throws -> [[String]] {
        enum State { case start, unquoted, quoted, afterQuote }
        var state = State.start
        var rows: [[String]] = [], row: [String] = []
        var field = ""
        func endField() { row.append(field); field = ""; state = .start }
        func endRow() {
            endField()
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
        }
        for character in text {
            if state == .quoted {
                if character == "\"" { state = .afterQuote } else { field.append(character) }
            } else if character == "," {
                endField()
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                endRow()
            } else if character == "\"" {
                switch state {
                case .start: state = .quoted
                case .afterQuote: field.append("\""); state = .quoted
                default: throw Failure.invalidCSV
                }
            } else {
                guard state != .afterQuote else { throw Failure.invalidCSV }
                field.append(character); state = .unquoted
            }
        }
        guard state != .quoted else { throw Failure.invalidCSV }
        if !field.isEmpty || !row.isEmpty || state != .start { endRow() }
        return rows
    }
}
