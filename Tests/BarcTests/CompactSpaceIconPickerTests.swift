// Modified for Barc: compact Space picker behavior and bundled catalog coverage, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Compact Space icon picker", .serialized)
@MainActor
struct CompactSpaceIconPickerTests {
    @Test("All 56 source icons resolve, including Arc's camel-case saved names")
    func symbols() {
        #expect(SpaceSymbols.choices.count == 56)
        #expect(Set(SpaceSymbols.choices.map(\.storedName)).count == 56)
        #expect(FolderSymbols.choices.count == 24, "The small folder palette keeps its original layout")
        for choice in SpaceSymbols.choices {
            #expect(SpaceSymbols.storedName(forArcName: choice.sourceName) == choice.storedName)
            #expect(FolderSymbols.image(named: choice.storedName)?.tiffRepresentation != nil)
        }
        #expect(SpaceSymbols.storedName(forArcName: "fileTrayFull") == "ionicon.file-tray-full")
        #expect(SpaceSymbols.storedName(forArcName: "colorPallete") == "ionicon.color-palette")
        #expect(SpaceSymbols.storedName(forArcName: "bag") == "ionicon.basket")
        for category in SpaceEmojiCatalog.Category.allCases {
            #expect(SpaceSymbols.image(named: category.symbol)?.tiffRepresentation != nil)
        }
        #expect(SpaceSymbols.storedName(forArcName: "../invalid") == nil)
    }
    @Test("Unicode search handles words, graphemes and the eight category groups")
    func emojiSearch() throws {
        #expect(SpaceEmojiCatalog.entries.count > 1800)
        #expect(Set(SpaceEmojiCatalog.entries.map(\.glyph)).count == SpaceEmojiCatalog.entries.count)
        #expect(Set(SpaceEmojiCatalog.entries.map(\.category)) == Set(SpaceEmojiCatalog.Category.allCases))
        #expect(SpaceEmojiCatalog.matching("COW").contains { $0.glyph == "🐮" })
        #expect(SpaceEmojiCatalog.matching("united kingdom").contains { $0.glyph == "🇬🇧" })
        #expect(SpaceEmojiCatalog.matching("❤️").contains { $0.glyph == "❤️" })
        #expect(SpaceEmojiCatalog.matching("no-such-emoji-123xyz").isEmpty)
        let index = try #require(SpaceEmojiCatalog.index(of: "👍🏽"))
        #expect(SpaceEmojiCatalog.entries[index].glyph == "👍")
        let cow = try #require(SpaceEmojiCatalog.index(of: "🐮"))
        #expect(Array(SpaceEmojiCatalog.entries[(cow - 4)...(cow + 3)].map(\.glyph)) == ["🦄", "🦓", "🦌", "🦬", "🐮", "🐂", "🐃", "🐄"])
    }
    @Test("The real compact picker maps filtered and symbol selections without changing anything on open")
    func selecting() throws {
        _ = NSApplication.shared
        var choices: [SpaceIcon] = []
        let picker = CompactSpaceIconPicker(selected: .symbol("ionicon.planet")) { choices.append($0) }
        _ = picker.view
        #expect(picker.preferredContentSize == NSSize(width: 270, height: 270))
        #expect(picker.mode == .icon)
        #expect(choices.isEmpty)
        let cloud = try #require(SpaceSymbols.choices.firstIndex { $0.sourceName == "cloudOutline" })
        picker.chooseItem(at: cloud)
        #expect(choices == [.symbol("ionicon.cloud-outline")])
        picker.setMode(.emoji)
        picker.searchFor("united kingdom")
        let flag = try #require(picker.displayedEmoji.firstIndex { $0.glyph == "🇬🇧" })
        picker.chooseItem(at: flag)
        #expect(choices.last == .emoji("🇬🇧"))
        picker.searchFor("no-such-emoji-123xyz")
        picker.chooseItem(at: 0)
        picker.chooseItem(at: -1)
        #expect(choices.count == 2)
        picker.searchFor("")
        #expect(picker.displayedEmoji.count == SpaceEmojiCatalog.entries.count)
    }
    @Test("Emoji and automatic icons start in Emoji mode and preserve compound emoji")
    func emojiMode() throws {
        let picker = CompactSpaceIconPicker(selected: .emoji("🐮")) { _ in }
        #expect(picker.mode == .emoji)
        #expect(CompactSpaceIconPicker(selected: .automatic) { _ in }.mode == .emoji)
        let family = "👨‍👩‍👧‍👦"
        var result: SpaceIcon?
        let familyPicker = CompactSpaceIconPicker(selected: .automatic) { result = $0 }
        familyPicker.searchFor(family)
        let index = try #require(familyPicker.displayedEmoji.firstIndex { $0.glyph == family })
        familyPicker.chooseItem(at: index)
        #expect(result == .emoji(family))
    }
}
