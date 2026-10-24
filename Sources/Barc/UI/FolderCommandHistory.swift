// Modified for Barc: query-specific folder command choices, 2026-10-24.
import Foundation

/// A folder chosen for one query does not become the answer to every query.
/// Bounded, profile-local records mirror the source command bar's saved choice.
struct FolderCommandHistory: Codable, Equatable {
    private struct Selection: Codable, Equatable {
        let folderID: UUID
        let selectedAt: Date
    }
    private var selections: [String:Selection] = [:]
    static let maximumCount = 256
    var count: Int { selections.count }

    func preferredFolder(for query: String) -> UUID? {
        Self.key(query).flatMap { selections[$0]?.folderID }
    }

    mutating func record(_ folderID: UUID, for query: String, at date: Date = .now) {
        guard let query = Self.key(query), date.timeIntervalSinceReferenceDate.isFinite else { return }
        selections[query] = Selection(folderID:folderID,selectedAt:date)
        if selections.count > Self.maximumCount {
            let retained = selections.sorted {
                if $0.value.selectedAt != $1.value.selectedAt { return $0.value.selectedAt > $1.value.selectedAt }
                return $0.key < $1.key
            }.prefix(Self.maximumCount)
            selections = Dictionary(uniqueKeysWithValues:retained.map { ($0.key,$0.value) })
        }
    }

    private static func key(_ query: String) -> String? {
        let value = query.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil)
            .trimmingCharacters(in:.whitespacesAndNewlines)
        return value.isEmpty || value.count > 512 ? nil : value
    }
}
