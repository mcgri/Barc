// Modified for Barc: verify supported Arc folder choices across snapshot, import and profile persistence, 2026-10-24.
import AppKit
import Foundation
import Testing
@testable import Barc

// Share the existing serialized suite: the importer deliberately permits only
// one run across all windows, including when an async test yields the actor.
extension ArcImportFlowTests {
    private func choice(_ folder: String, at date: Any = 100) -> [String:Any] {
        ["selectedAt":date,"archetype":["type":"typeTravel","associatedValues":["associatedValue0":[
            "openFolder":["folderID":folder,"folderName":"An unrelated display name"]]]]]
    }

    private func ranking(_ profiles: [String:[String:Any]], version: Int = 2) throws -> Data {
        try JSONSerialization.data(withJSONObject:["version":version,"dataByProfile":profiles.mapValues {
            ["queriesToSelectedArchetype":$0,"recentlySwitchedToTabs":[],"typeTravelUsage":[:]] as [String:Any]
        }])
    }

    private func options() -> ArcImportOptions {
        var result = ArcImportOptions(profileIDs:["Default","Profile 1"])
        result.history = false; result.bookmarks = false; result.passwords = false
        result.cookies = false; result.localStorage = false; result.supplementary = false
        return result
    }

    @Test("Only explicit folder actions survive parsing; normalized duplicate queries use the latest choice")
    func supportedRecordsOnly() throws {
        let data = try ranking(["Default":[
            " RÉSEARCH ":choice("older",at:100),"research":choice("newer",at:200),
            "bad date":choice("folder",at:true),"empty folder":choice(""),
            "not a folder":["selectedAt":100,"archetype":["type":"chromiumArchetype",
                "associatedValues":["url":"https://private.invalid/never-import-this-query"]]],
            String(repeating:"x",count:513):choice("folder")],"Profile 1":[:],"../outside":["research":choice("folder")]])
        let read = try ArcCommandRankingReader.read(data)
        #expect(Set(read.profiles.keys) == ["Default","Profile 1"])
        #expect(read.profiles["Default"] == [.init(query:"research",folderID:"newer",selectedAt:Date(timeIntervalSinceReferenceDate:200))])
        #expect(read.profiles["Profile 1"] == [])
        #expect(throws:(any Error).self) { try ArcCommandRankingReader.read(ranking([:],version:3)) }
        #expect(throws:(any Error).self) { try ArcCommandRankingReader.read(Data("{}".utf8)) }
    }

    @Test("A sidebar-only snapshot copies choice metadata privately and malformed optional metadata does not block the sidebar")
    func privateSnapshot() throws {
        let root = try ArcImportBench.directory(); defer { try? FileManager.default.removeItem(at:root) }
        let arc = root.appending(path:"Arc")
        _ = try ArcFlowBench.source(in:arc)
        let file = arc.appending(path:ArcCommandRankingReader.filename)
        let original = try ranking(["Default":["research":choice("folder")]])
        try original.write(to:file)
        let snapshot = try ArcSourceSnapshotter.capture(arc,temporaryParent:root,sidebarOnly:true)
        defer { snapshot.remove() }
        let copy = snapshot.root.appending(path:ArcCommandRankingReader.filename)
        #expect(try Data(contentsOf:copy) == original && Data(contentsOf:file) == original)
        #expect((try FileManager.default.attributesOfItem(atPath:copy.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(snapshot.commandRanking?.profiles["Default"]?.first?.folderID == "folder")
        try Data("invalid optional metadata".utf8).write(to:file)
        let malformed = try ArcSourceSnapshotter.capture(arc,temporaryParent:root,sidebarOnly:true)
        defer { malformed.remove() }
        #expect(malformed.commandRanking == nil && !malformed.sidebar.spaces.isEmpty)
    }

    @Test("Imported choices fill free slots without replacing or evicting local choices")
    func boundedMerge() {
        let local = UUID(), imported = UUID()
        var history = FolderCommandHistory()
        history.record(local,for:"keep",at:Date(timeIntervalSinceReferenceDate:0))
        var choices = (0..<300).map { FolderCommandHistory.ImportedChoice(query:"source \($0)",folderID:imported,selectedAt:Date(timeIntervalSinceReferenceDate:Double($0))) }
        choices.append(.init(query:"keep",folderID:imported,selectedAt:Date(timeIntervalSinceReferenceDate:1000)))
        choices.append(.init(query:"invalid",folderID:imported,selectedAt:Date(timeIntervalSinceReferenceDate:.infinity)))
        #expect(history.importChoices(choices) == 255 && history.count == 256)
        #expect(history.preferredFolder(for:"keep") == local)
        #expect(history.preferredFolder(for:"source 299") == imported)
        #expect(history.preferredFolder(for:"source 45") == imported && history.preferredFolder(for:"source 44") == nil)
        #expect(history.importChoices(choices) == 0 && history.preferredFolder(for:"invalid") == nil)
    }

    @Test("Choices resolve after every selected profile has imported, retain their origin profile and survive restart")
    func orchestrationAndPersistence() async throws {
        let root = try ArcImportBench.directory(); defer { try? FileManager.default.removeItem(at:root) }
        let arc = root.appending(path:"Arc")
        _ = try ArcFlowBench.source(in:arc)
        let sidebarFile = arc.appending(path:"StorableSidebar.json")
        var document = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:sidebarFile)) as? [String:Any])
        var sidebar = try #require(document["sidebar"] as? [String:Any])
        var containers = try #require(sidebar["containers"] as? [[String:Any]])
        var items = try #require(containers[1]["items"] as? [Any])
        items += ["work-folder",ArcImportBench.item("work-folder",parent:"work-tabs",folder:true)]
        containers[1]["items"] = items; sidebar["containers"] = containers; document["sidebar"] = sidebar
        try JSONSerialization.data(withJSONObject:document).write(to:sidebarFile)
        try ranking(["Default":["research":choice("work-folder"),"missing":choice("missing-folder")],
            "Profile 1":["research":choice("folder")]]).write(to:arc.appending(path:ArcCommandRankingReader.filename))
        let source = try ArcSourceSnapshotter.capture(arc,temporaryParent:root,sidebarOnly:true)
        defer { source.remove() }
        let session = BrowserSession(database:nil,sessionStore:SessionStore(fileURL:root.appending(path:"session.json")))
        let settingsName = "arc-folder-choice.\(UUID())", defaults = UserDefaults(suiteName:settingsName)!
        defer { defaults.removePersistentDomain(forName:settingsName) }
        let coordinator = ArcImportCoordinator(session:session,settings:Settings(defaults:defaults),
            downloads:DownloadManager(store:DownloadStore(fileURL:root.appending(path:"downloads.json"))),reportDirectory:root.appending(path:"reports"))
        let report = try await coordinator.run(source,options:options())
        let personal = try #require(session.spaces.first { $0.id == ArcImportID.uuid(source.sourceFingerprint+"/space/personal-space") })
        let work = try #require(session.spaces.first { $0.id == ArcImportID.uuid(source.sourceFingerprint+"/space/work-space") })
        let workFolder = ArcImportID.uuid(source.sourceFingerprint+"/group/work-space/work-folder")
        let personalFolder = ArcImportID.uuid(source.sourceFingerprint+"/group/personal-space/folder")
        #expect(session.preferredFolderCommand(for:"RESEARCH",profile:personal.profile) == workFolder)
        #expect(session.preferredFolderCommand(for:"research",profile:work.profile) == personalFolder)
        #expect(session.preferredFolderCommand(for:"missing",profile:personal.profile) == nil)
        #expect(report.profiles.first { $0.folder == "Default" }?.counts["Folder search choices"]?.imported == 1)
        #expect(report.profiles.first { $0.folder == "Default" }?.counts["Folder search choices"]?.skipped == 1)
        let persisted = try JSONDecoder().decode(SessionSnapshot.self,from:Data(contentsOf:root.appending(path:"session.json")))
        let restored = try #require(BrowserSession.spaces(from:persisted)?.first { $0.id == personal.id })
        #expect(restored.profile.preferences.folderCommandHistory?.preferredFolder(for:"research") == workFolder)
        #expect(restored.profile.preferences.arcFolderCommandSources == [source.sourceFingerprint+"/Default"])
        var changed = source
        changed.commandRanking = try ArcCommandRankingReader.read(ranking(["Default":["research":choice("folder",at:200)]]))
        _ = try await coordinator.run(changed,options:options())
        #expect(session.preferredFolderCommand(for:"research",profile:personal.profile) == workFolder)
        session.selectSpace(personal); session.clearHistory()
        _ = try await coordinator.run(changed,options:options())
        #expect(personal.profile.preferences.folderCommandHistory?.count == 0)
        #expect(session.preferredFolderCommand(for:"research",profile:work.profile) == personalFolder)
    }

    @Test("Explicitly cleared and private histories cannot be repopulated through import")
    func clearingAndPrivateBoundaries() {
        let session = TestSession.make().0, ordinary = session.activeSpace
        let folder = session.createGroup(named:"Research")
        let choice = FolderCommandHistory.ImportedChoice(query:"research",folderID:folder.id,selectedAt:.now)
        ordinary.profile.preferences.folderCommandHistory = FolderCommandHistory()
        #expect(session.enrichArcFolderCommands([choice],for:ordinary.identity,sourceID:"source") == 0)
        #expect(ordinary.profile.preferences.arcFolderCommandSources == ["source"])
        let secret = session.addSpace(named:"Private",isPrivate:true)
        #expect(session.enrichArcFolderCommands([choice],for:secret.identity,sourceID:"private-source") == 0)
        #expect(secret.profile.preferences.folderCommandHistory == nil && secret.profile.preferences.arcFolderCommandSources == nil)
    }

    @Test("A first import preserves local choices, rejects private destinations and fills missing normal choices")
    func existingLocalChoices() throws {
        let session = TestSession.make().0, ordinary = session.activeSpace
        let local = session.createGroup(named:"Local")
        let incoming = session.createGroup(named:"Imported")
        session.rememberFolderCommand(local,in:ordinary,query:"research",profile:ordinary.profile)
        let secret = session.addSpace(named:"Private",isPrivate:true)
        let privateFolder = session.createGroup(named:"Private folder")
        let choices: [FolderCommandHistory.ImportedChoice] = [
            .init(query:"research",folderID:incoming.id,selectedAt:.now),
            .init(query:"missing normal choice",folderID:incoming.id,selectedAt:.now),
            .init(query:"private destination",folderID:privateFolder.id,selectedAt:.now)]
        #expect(session.enrichArcFolderCommands(choices,for:ordinary.identity,sourceID:"source") == 1)
        #expect(session.preferredFolderCommand(for:"research",profile:ordinary.profile) == local.id)
        #expect(session.preferredFolderCommand(for:"missing normal choice",profile:ordinary.profile) == incoming.id)
        #expect(session.preferredFolderCommand(for:"private destination",profile:ordinary.profile) == nil)
        #expect(secret.profile.preferences.folderCommandHistory == nil)
        #expect(session.enrichArcFolderCommands(choices,for:ordinary.identity,sourceID:"source") == 0)
    }
}
