// Modified for Barc: import only supported, profile-scoped folder search choices from Arc, 2026-10-24.
import CoreFoundation
import Foundation

struct ArcCommandRanking: Sendable {
    struct FolderSelection: Sendable, Equatable {
        let query: String
        let folderID: String
        let selectedAt: Date
    }
    let profiles: [String:[FolderSelection]]
}

enum ArcCommandRankingReader {
    static let filename = "StorableCommandBarAdditionalRanking.json"

    /// URL, tab and search archetypes stay in the private source snapshot.
    /// Only an explicit folder action can become a saved folder choice.
    static func read(_ data: Data) throws -> ArcCommandRanking {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let version = root["version"] as? NSNumber, version.doubleValue == 2,
              let profiles = root["dataByProfile"] as? [String:Any] else {
            throw ArcImportFailure.unreadable("saved folder search choices")
        }
        var result: [String:[ArcCommandRanking.FolderSelection]] = [:]
        for (profile, raw) in profiles where ArcSourceSnapshotter.validProfileName(profile) {
            guard let object = raw as? [String:Any],
                  let selections = object["queriesToSelectedArchetype"] as? [String:Any] else { continue }
            var choices: [String:ArcCommandRanking.FolderSelection] = [:]
            for (query, rawSelection) in selections {
                guard let query = FolderCommandHistory.normalizedQuery(query),
                      let selection = rawSelection as? [String:Any],
                      let timestamp = selection["selectedAt"] as? NSNumber,
                      CFGetTypeID(timestamp) != CFBooleanGetTypeID(), timestamp.doubleValue.isFinite,
                      let action = selection["archetype"] as? [String:Any], action["type"] as? String == "typeTravel",
                      let values = action["associatedValues"] as? [String:Any],
                      let value = values["associatedValue0"] as? [String:Any],
                      let folder = value["openFolder"] as? [String:Any],
                      let id = folder["folderID"] as? String, !id.isEmpty, id.count <= 512 else { continue }
                let choice = ArcCommandRanking.FolderSelection(query:query,folderID:id,
                    selectedAt:Date(timeIntervalSinceReferenceDate:timestamp.doubleValue))
                if let previous = choices[query], previous.selectedAt > choice.selectedAt
                    || (previous.selectedAt == choice.selectedAt && previous.folderID <= choice.folderID) { continue }
                choices[query] = choice
            }
            result[profile] = choices.values.sorted {
                if $0.selectedAt != $1.selectedAt { return $0.selectedAt > $1.selectedAt }
                return $0.query < $1.query
            }
        }
        return ArcCommandRanking(profiles:result)
    }
}
