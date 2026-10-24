// Modified for Barc: query-specific folder command choices, 2026-10-24.
import Foundation

/// A folder chosen for one query does not become the answer to every query.
/// Bounded, profile-local records mirror the source command bar's saved choice.
struct FolderCommandHistory: Codable, Equatable {
    struct ImportedChoice {
        let query: String
        let folderID: UUID
        let selectedAt: Date
    }
    private struct Selection: Codable, Equatable {
        let folderID: UUID
        let selectedAt: Date
    }
    private var selections: [String:Selection] = [:]
    static let maximumCount = 256
    var count: Int { selections.count }

    func preferredFolder(for query: String) -> UUID? {
        Self.normalizedQuery(query).flatMap { selections[$0]?.folderID }
    }

    mutating func record(_ folderID: UUID, for query: String, at date: Date = .now) {
        guard let query = Self.normalizedQuery(query), date.timeIntervalSinceReferenceDate.isFinite else { return }
        selections[query] = Selection(folderID:folderID,selectedAt:date)
        if selections.count > Self.maximumCount {
            let retained = selections.sorted {
                if $0.value.selectedAt != $1.value.selectedAt { return $0.value.selectedAt > $1.value.selectedAt }
                return $0.key < $1.key
            }.prefix(Self.maximumCount)
            selections = Dictionary(uniqueKeysWithValues:retained.map { ($0.key,$0.value) })
        }
    }

    /// Existing local choices retain both their value and their place in the
    /// bounded store. New source choices fill only the remaining slots.
    mutating func importChoices(_ choices: [ImportedChoice]) -> Int {
        let valid = choices.compactMap { choice -> ImportedChoice? in
            guard let query = Self.normalizedQuery(choice.query), choice.selectedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
            return ImportedChoice(query:query,folderID:choice.folderID,selectedAt:choice.selectedAt)
        }.sorted {
            if $0.selectedAt != $1.selectedAt { return $0.selectedAt > $1.selectedAt }
            if $0.query != $1.query { return $0.query < $1.query }
            return $0.folderID.uuidString < $1.folderID.uuidString
        }
        var added = 0
        for choice in valid where selections.count < Self.maximumCount && selections[choice.query] == nil {
            selections[choice.query] = Selection(folderID:choice.folderID,selectedAt:choice.selectedAt)
            added += 1
        }
        return added
    }

    static func normalizedQuery(_ query: String) -> String? {
        let value = query.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil)
            .trimmingCharacters(in:.whitespacesAndNewlines)
        return value.isEmpty || value.count > 512 ? nil : value
    }
}
