// Modified for Barc: import actual cached icons for the selected sidebar pages, 2026-10-24.
import Foundation

enum ArcFaviconReader {
    struct Result: Sendable {
        var icons: [String: Data] = [:]
        var skipped = 0
    }

    /// Reads only a private, frozen source copy. No website requests are made.
    static func read(_ profile: URL, pages: [URL]) throws -> Result {
        let file = profile.appending(path: "Favicons")
        guard FileManager.default.fileExists(atPath: file.path) else { return Result() }
        let keys = Set(pages.compactMap(PageFavicon.key))
        guard !keys.isEmpty else { return Result() }
        let database = try SQLiteDatabase(readingOnly: file.path)
        var result = Result()
        var sizes: [String: Int] = [:]
        let ordered = Set(pages.map(\.absoluteString)).union(keys).sorted()
        for start in stride(from: 0, to: ordered.count, by: 400) {
            let batch = Array(ordered[start..<min(start + 400, ordered.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try database.query("""
                SELECT m.page_url, b.image_data, b.width, b.height
                FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
                WHERE m.page_url IN (\(placeholders))
                  AND length(b.image_data) BETWEEN 1 AND \(FaviconDecoder.maximumByteCount)
                  AND b.width BETWEEN 1 AND \(FaviconDecoder.maximumSourcePixelSize)
                  AND b.height BETWEEN 1 AND \(FaviconDecoder.maximumSourcePixelSize)
                ORDER BY m.page_url, b.id DESC LIMIT 4096;
                """, batch.map(SQLiteDatabase.Value.text)) { row in
                    (row.text(0), try? FaviconDecoder.normalize(row.blob(1)), Int(row.integer(2)), Int(row.integer(3)))
            }
            for (raw, data, width, height) in rows {
                guard let raw, let url = URL(string: raw), let key = PageFavicon.key(for: url), keys.contains(key),
                      width > 0, height > 0,
                      width <= FaviconDecoder.maximumSourcePixelSize, height <= FaviconDecoder.maximumSourcePixelSize else {
                    result.skipped += 1
                    continue
                }
                let side = max(width, height)
                if let current = sizes[key], !FaviconDecoder.isBetter(side, than: current) { continue }
                guard let png = data else { result.skipped += 1; continue }
                result.icons[key] = png
                sizes[key] = side
            }
        }
        return result
    }

    static func githubBadge(_ profile: URL) throws -> Data? {
        let file = profile.appending(path: "Favicons")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let database = try SQLiteDatabase(readingOnly: file.path)
        let tables = try database.query("SELECT name FROM sqlite_master WHERE type='table';") { $0.text(0) ?? "" }
        guard tables.contains("favicons") else { return nil }
        let candidates = try database.query("""
            SELECT b.image_data FROM favicon_bitmaps b JOIN favicons f ON f.id = b.icon_id
            WHERE (f.url LIKE 'https://github.com/favicon.%' OR f.url LIKE 'https://github.githubassets.com/favicons/%')
              AND length(b.image_data) BETWEEN 1 AND \(FaviconDecoder.maximumByteCount)
              AND b.width BETWEEN 1 AND \(FaviconDecoder.maximumSourcePixelSize)
              AND b.height BETWEEN 1 AND \(FaviconDecoder.maximumSourcePixelSize)
            ORDER BY ABS(b.width - 32), b.id DESC LIMIT 16;
            """) { try? FaviconDecoder.normalize($0.blob(0)) }
        return candidates.compactMap { $0 }.first
    }
}
