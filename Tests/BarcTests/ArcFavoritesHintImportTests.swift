// Modified for Barc: verify Arc's profile-scoped Favorites hint setting without copying unrelated Mac preferences, 2026-10-24.
import AppKit
import Foundation
import Testing
@testable import Barc

// Import runs share this serialized suite and its global single-run guard.
extension ArcImportFlowTests {
    private func hintPreferences(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList:[
            "topAppsEmptyStateDismissedForProfiles":value,
            "unrelatedSetting":"never-copy-unrelated-arc-preferences-value"
        ],format:.binary,options:0)
    }

    @Test("Only the supported profile names are read from Arc's Mac preferences")
    func favoritesHintPreferenceReader() throws {
        let profiles=ArcImportBench.profiles
        #expect(ArcMacPreferencesReader.dismissedFavoritesProfiles(try hintPreferences(["Profile 1","unknown"]),profiles:profiles)==["Profile 1"])
        #expect(ArcMacPreferencesReader.dismissedFavoritesProfiles(try hintPreferences([String]()),profiles:profiles)==[])
        #expect(ArcMacPreferencesReader.dismissedFavoritesProfiles(try hintPreferences(["Profile 1",true]),profiles:profiles)==nil)
        #expect(ArcMacPreferencesReader.dismissedFavoritesProfiles(Data("invalid plist".utf8),profiles:profiles)==nil)
    }

    @Test("Explicit source preferences are projected into a private sidebar snapshot; other Arc folders do not borrow local settings")
    func favoritesHintSnapshot() throws {
        let root=try ArcImportBench.directory(); defer { try? FileManager.default.removeItem(at:root) }
        let arc=root.appending(path:"Arc")
        _=try ArcFlowBench.source(in:arc)
        let file=root.appending(path:"Arc Defaults.plist"),data=try hintPreferences(["Profile 1"])
        try data.write(to:file)
        let snapshot=try ArcSourceSnapshotter.capture(arc,temporaryParent:root,sidebarOnly:true,macPreferencesURL:file)
        defer { snapshot.remove() }
        #expect(snapshot.favoritesHintDismissedProfiles==["Profile 1"])
        #expect(try Data(contentsOf:file)==data)
        let files=try #require(FileManager.default.enumerator(at:snapshot.root,includingPropertiesForKeys:[.isRegularFileKey]))
        let marker=Data("never-copy-unrelated-arc-preferences-value".utf8)
        for case let url as URL in files where (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true {
            #expect(try !Data(contentsOf:url).contains(marker))
        }
        let unrelated=try ArcSourceSnapshotter.capture(arc,temporaryParent:root,sidebarOnly:true)
        defer { unrelated.remove() }
        #expect(unrelated.favoritesHintDismissedProfiles==nil)
    }

    @Test("An imported hint follows its profile, is durable immediately, and later local choices survive reimport")
    func favoritesHintOrchestration() async throws {
        let root=try ArcImportBench.directory(); defer { try? FileManager.default.removeItem(at:root) }
        let arc=root.appending(path:"Arc")
        _=try ArcFlowBench.source(in:arc)
        let file=root.appending(path:"Arc Defaults.plist"); try hintPreferences(["Profile 1"]).write(to:file)
        let source=try ArcSourceSnapshotter.capture(arc,temporaryParent:root,sidebarOnly:true,macPreferencesURL:file)
        defer { source.remove() }
        let store=SessionStore(fileURL:root.appending(path:"session.json"))
        let session=BrowserSession(database:nil,sessionStore:store)
        let settingsName="arc-favorites-hint.\(UUID())",defaults=UserDefaults(suiteName:settingsName)!
        defer { defaults.removePersistentDomain(forName:settingsName) }
        let coordinator=ArcImportCoordinator(session:session,settings:Settings(defaults:defaults),
            downloads:DownloadManager(store:DownloadStore(fileURL:root.appending(path:"downloads.json"))),reportDirectory:root.appending(path:"reports"))
        var options=ArcImportOptions(profileIDs:["Default","Profile 1"])
        options.history=false; options.bookmarks=false; options.passwords=false
        options.cookies=false; options.localStorage=false; options.supplementary=false
        let report=try await coordinator.run(source,options:options)
        let personal=try #require(session.spaces.first { $0.id==ArcImportID.uuid(source.sourceFingerprint+"/space/personal-space") })
        let work=try #require(session.spaces.first { $0.id==ArcImportID.uuid(source.sourceFingerprint+"/space/work-space") })
        #expect(!personal.favoritesHintDismissed && work.favoritesHintDismissed)
        #expect(report.profiles.first { $0.folder=="Profile 1" }?.counts["Favorites hint preference"]?.verified==1)
        let persisted=try JSONDecoder().decode(SessionSnapshot.self,from:Data(contentsOf:store.fileURL))
        let restored=try #require(BrowserSession.spaces(from:persisted)?.first { $0.id==work.id })
        #expect(restored.favoritesHintDismissed && restored.profile.preferences.favoritesHintDismissed==true)
        let sibling=session.addSpace(named:"Same profile",profile:work.profile)
        #expect(sibling.favoritesHintDismissed)
        session.dismissFavoritesHint(in:personal)
        var changed=source; changed.favoritesHintDismissedProfiles=[]
        _=try await coordinator.run(changed,options:options)
        #expect(personal.favoritesHintDismissed && work.favoritesHintDismissed && sibling.favoritesHintDismissed)
    }

    @Test("A legacy Space dismissal becomes the shared profile's choice when restoring")
    func legacyFavoritesHint() throws {
        let session=TestSession.make().0
        var snapshot=session.snapshot()
        snapshot.spaces[0].look?.favoritesHintDismissed=true
        snapshot.spaces.append(.init(id:UUID(),name:"Sibling",identity:session.activeSpace.identity))
        let restored=try #require(BrowserSession.spaces(from:snapshot))
        #expect(restored.count==2 && restored.allSatisfy(\.favoritesHintDismissed))
        #expect(restored[0].profile===restored[1].profile)
        #expect(restored[0].profile.preferences.favoritesHintDismissed==true)
    }
}
