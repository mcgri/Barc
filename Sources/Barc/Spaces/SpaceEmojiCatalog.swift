// Modified for Barc: searchable Space emoji with the compact eight-category order, 2026-10-24.
import Foundation

enum SpaceEmojiCatalog {
    enum Category: Int, CaseIterable, Sendable {
        case people, nature, food, activities, travel, objects, symbols, flags
        var title: String {
            switch self {
            case .people: "Smileys and people"
            case .nature: "Animals and nature"
            case .food: "Food and drink"
            case .activities: "Activities"
            case .travel: "Travel and places"
            case .objects: "Objects"
            case .symbols: "Symbols"
            case .flags: "Flags"
            }
        }
        var symbol: String {
            switch self {
            case .people: "face.smiling"
            case .nature: "sun.max"
            case .food: "cup.and.saucer"
            case .activities: "rosette"
            case .travel: "box.truck"
            case .objects: "gift"
            case .symbols: "heart"
            case .flags: "flag"
            }
        }
    }
    struct Entry: Equatable, Sendable {
        let glyph: String
        let name: String
        let category: Category
    }

    static func matching(_ query: String) -> [Entry] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty else { return entries }
        let glyph = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return entries.filter { entry in
            if normalized(entry.glyph) == glyph { return true }
            return terms.allSatisfy { entry.name.localizedStandardContains(String($0)) }
        }
    }

    /// Accept emoji saved without presentation selectors, and locate a saved
    /// skin-tone variant at its default glyph rather than losing its category.
    static func normalized(_ glyph: String) -> String {
        String(String.UnicodeScalarView(glyph.unicodeScalars.filter {
            $0.value != 0xFE0F && !(0x1F3FB...0x1F3FF).contains($0.value)
        }))
    }
    static func index(of glyph: String, in entries: [Entry] = entries) -> Int? {
        let key = normalized(glyph)
        return entries.firstIndex { normalized($0.glyph) == key }
    }
}
