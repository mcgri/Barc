// Modified for Barc: browse actual downloads, archives and Boosts in the Library, 2026-10-24.
// Modified for Barc: archive search includes every split member, 2026-10-25.
import Foundation
import UniformTypeIdentifiers

enum LibraryCategory: String, CaseIterable, Sendable {
    case media, downloads, easels, spaces, boosts, archive

    var title: String {
        switch self {
        case .media: "Media"
        case .downloads: "Downloads"
        case .easels: "Easels"
        case .spaces: "Spaces"
        case .boosts: "Boosts"
        case .archive: "Archived Tabs"
        }
    }
    var symbol: String {
        switch self {
        case .media: "photo.on.rectangle.angled"
        case .downloads: "arrow.down.circle"
        case .easels: "rectangle.on.rectangle"
        case .spaces: "rectangle.portrait.on.rectangle.portrait.angled"
        case .boosts: "paintbrush.pointed"
        case .archive: "archivebox"
        }
    }
    var searchPlaceholder: String { "Search \(self == .archive ? "Archive" : title)…" }
}

enum LibraryFileKind: String, CaseIterable, Sendable {
    case image = "Images", movie = "Videos", audio = "Audio", document = "Documents", other = "Other Files"

    static func of(_ url: URL) -> Self {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .movie }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .presentation) || type.conforms(to: .compositeContent) { return .document }
        return .other
    }
}

struct LibraryEntry: Identifiable {
    enum ID: Hashable { case download(UUID), archived(UUID), boost(UUID) }
    let id: ID
    let title: String
    let subtitle: String
    let date: Date
    var url: URL?
    var file: URL?
    var spaceIDs: Set<UUID> = []
    var kind: LibraryFileKind?
    var favicon: Data?
}

struct LibraryQuery {
    var text = ""
    var spaceID: UUID?
    var fileKind: LibraryFileKind?

    func apply(to entries: [LibraryEntry]) -> [LibraryEntry] {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            if let spaceID, !entry.spaceIDs.contains(spaceID) { return false }
            if let fileKind, entry.kind != fileKind { return false }
            let haystack = [entry.title, entry.subtitle, entry.url?.absoluteString ?? ""].joined(separator: " ")
            return terms.allSatisfy { haystack.localizedStandardContains($0) }
        }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

@MainActor
enum LibraryCatalog {
    static func entries(for category: LibraryCategory, session: BrowserSession,
                        downloads: DownloadManager, boosts: BoostStore) -> [LibraryEntry] {
        switch category {
        case .downloads, .media:
            return downloads.downloads.compactMap { download in
                let kind = LibraryFileKind.of(download.destination)
                if category == .media && ![.image, .movie, .audio].contains(kind) { return nil }
                let noun: String
                switch kind {
                case .image: noun = "Image"
                case .movie: noun = "Movie"
                case .audio: noun = "Audio"
                case .document: noun = "Document"
                case .other: noun = download.destination.pathExtension.lowercased() == "dmg" ? "Disk Image" : "Download"
                }
                let subtitle = download.sourceURL.host().map { "\(noun) from \($0)" } ?? noun
                let ids = Set(session.spaces.filter {
                    download.sourceProfileKey == nil || ProfileDataPaths.key(for: $0.identity) == download.sourceProfileKey
                }.map(\.id))
                return LibraryEntry(id: .download(download.id), title: download.filename, subtitle: subtitle,
                                    date: download.startedAt, url: download.sourceURL, file: download.destination,
                                    spaceIDs: ids, kind: kind)
            }
        case .archive:
            return session.archivedTabs.map { record in
                LibraryEntry(id: .archived(record.id), title: record.title,
                             subtitle: record.snapshots.map { $0.url.absoluteString }.joined(separator:" · "), date: record.archivedAt,
                             url: record.snapshot.url, spaceIDs: [record.spaceID], favicon: record.snapshot.favicon?.data)
            }
        case .boosts:
            return boosts.boosts.map { boost in
                LibraryEntry(id: .boost(boost.id), title: boost.name, subtitle: boost.host,
                             date: boost.dateModified, url: URL(string: "https://" + boost.host))
            }
        case .easels, .spaces: return []
        }
    }
}
