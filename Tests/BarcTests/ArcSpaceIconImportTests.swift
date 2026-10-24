import AppKit
import Testing
@testable import Barc

@Suite("Arc Space icon import", .serialized)
@MainActor
struct ArcSpaceIconImportTests {
    @Test("Arc's planet icon passes from its real iconType shape into a rendered Space symbol")
    func sourcePlanet() throws {
        var root = try #require(JSONSerialization.jsonObject(with: ArcImportBench.sidebar()) as? [String: Any])
        var sidebar = try #require(root["sidebar"] as? [String: Any])
        var containers = try #require(sidebar["containers"] as? [[String: Any]])
        var spaces = try #require(containers[1]["spaces"] as? [Any])
        var space = try #require(spaces[1] as? [String: Any])
        var info = space["customInfo"] as? [String: Any] ?? [:]
        info["iconType"] = ["icon": "planet"]
        space["customInfo"] = info; spaces[1] = space
        containers[1]["spaces"] = spaces; sidebar["containers"] = containers; root["sidebar"] = sidebar
        let source = try ArcImportBench.snapshot()
        defer { source.remove() }
        let parsed = try ArcSidebarReader.read(sidebar: JSONSerialization.data(withJSONObject: root), archive: nil, profiles: source.profiles)
        let input = ArcSourceSnapshot(root: source.root, sourceFingerprint: source.sourceFingerprint, profiles: source.profiles,
            sidebar: parsed, unsupportedIndexedDBFolders: [:], extensions: [:])
        let built = try #require(ArcSpaceBuilder.build(input, options: .init(profileIDs: ["Default"])).first?.snapshot)
        #expect(built.icon == .symbol("ionicon.planet"))
        let restored = try #require(BrowserSession.spaces(from: SessionSnapshot(spaces: [built], activeSpaceIndex: 0))?.first)
        #expect(restored.icon == .symbol("ionicon.planet"))
        #expect(restored.dotImage(side: 18).tiffRepresentation != nil)
        #expect(!restored.look.spaceIconWasCustomized)
    }

    @Test("Enriching an older iconless import changes only the icon, and respects later explicit choices")
    func enrichAndRespectChoices() throws {
        let (session, store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let space = session.activeSpace
        var incoming = session.snapshot().spaces[0]
        incoming.icon = .symbol("ionicon.planet")
        let tabs = space.tabs.map(\.id), profile = space.profile
        let look = space.look
        _ = try session.applyArcSpaces([incoming])
        #expect(space.icon == .symbol("ionicon.planet") && space.look == look)
        #expect(space.tabs.map(\.id) == tabs && space.profile === profile)
        session.setIcon(.emoji("🌱"), for: space)
        _ = try session.applyArcSpaces([incoming])
        #expect(space.icon == .emoji("🌱"))
        session.setIcon(.automatic, for: space)
        session.saveNow()
        let reopened = BrowserSession(database: nil, sessionStore: store,
            settings: Settings(defaults: UserDefaults(suiteName: "arc-icon.\(UUID())")!))
        let restored = try #require(reopened.spaces.first { $0.id == space.id })
        #expect(restored.look.spaceIconWasCustomized)
        _ = try reopened.applyArcSpaces([incoming])
        #expect(restored.icon == .automatic, "Remove Icon must survive repeat imports too")
    }

    @Test("An explicit automatic choice is remembered even when the displayed icon does not change")
    func automaticChoice() throws {
        let (session, store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let space = session.activeSpace
        session.setIcon(.automatic, for: space)
        session.saveNow()
        let snapshot = try #require(store.load())
        #expect(snapshot.spaces[0].look?.spaceIconWasCustomized == true)
        var incoming = snapshot.spaces[0]; incoming.icon = .emoji("🌱")
        _ = try session.applyArcSpaces([incoming])
        #expect(space.icon == .automatic)
    }
}
