// Modified for Barc: imported download retention and profile attribution, 2026-10-23.
import Foundation

/// Reads and writes the downloads list as one JSON file.
///
/// Same shape as the session store, and for the same reason: a short list
/// that is always rewritten whole and read exactly once at launch. It is a
/// separate file rather than a table in `browser.sqlite` because nothing
/// about it is queried — the whole list is the query.
struct DownloadStore {
    /// The list is capped rather than kept forever. It is a convenience for
    /// finding a file again, not an archive; the files themselves are the
    /// record, and they are in Downloads.
    static let limit = 100

    let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "downloads.json")) {
        self.fileURL = fileURL
    }

    func load() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return [] }
        return Self.retained(records)
    }

    /// Atomic, so a crash mid-write cannot leave a truncated list behind.
    func save(_ records: [DownloadRecord]) throws {
        AppPaths.ensureSupportDirectory()
        let data = try JSONEncoder().encode(Self.retained(records))
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Imported history is an explicit archive, not the convenience queue of
    /// recent downloads. A new download must not silently discard that import.
    static func retained(_ records: [DownloadRecord]) -> [DownloadRecord] {
        var ordinary = 0
        return records.filter { record in
            if record.importedFromArc == true { return true }
            ordinary += 1
            return ordinary <= limit
        }
    }
}
