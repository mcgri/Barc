import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

@Suite("Browsing profiles shared by Spaces")
@MainActor
struct BrowsingProfileTests {
    private func profile(_ session: BrowserSession, _ name: String = "Work") throws -> BrowserProfile {
        try #require(session.addProfile(named: name))
    }

    @Test("Two layouts can share one profile, one Favorite tab and one data store")
    func sharedFavorite() throws {
        let session = TestSession.make().0
        let shared = try profile(session)
        let first = session.addSpace(named: "Projects", profile: shared)
        let favorite = session.newTab(url: URL(string: "https://favorite.invalid/")!)
        session.pin(favorite)
        let pin = try #require(first.pinnedSites.first)
        let second = session.addSpace(named: "Writing", profile: shared)
        let before = session.allTabs.count
        #expect(first.profile === second.profile)
        #expect(first.tab(forPin: pin.id) === second.tab(forPin: pin.id))
        session.openPinnedSite(pin)
        #expect(session.activeTab === favorite)
        #expect(session.allTabs.count == before)
        #expect(Set(session.allTabs.map(\.id)).count == before)
        #expect(favorite.currentWebView == nil)
        session.revealTab(id: favorite.id)
        #expect(session.activeSpace === second, "Revealing a shared Favorite stays in the current Space")
        #expect(WebEnvironment.shared.dataStore(for: first.identity) === WebEnvironment.shared.dataStore(for: second.identity))
        WebEnvironment.shared.releaseDataStore(for: shared.identity)
    }

    @Test("Closing a shared Favorite closes its page once, keeps its tile and repairs both layouts")
    func closeSharedFavorite() throws {
        let session = TestSession.make().0
        let shared = try profile(session)
        let first = session.addSpace(named: "First", profile: shared)
        let favorite = session.newTab(url: URL(string: "https://favorite.invalid/")!)
        session.pin(favorite)
        let pin = try #require(shared.pinnedSites.first)
        let second = session.addSpace(named: "Second", profile: shared)
        session.openPinnedSite(pin)
        #expect(session.closeTab(favorite))
        #expect(shared.favoriteTabs.isEmpty)
        #expect(shared.pinnedSites.count == 1)
        #expect(first.activeTab != nil && second.activeTab != nil)
        #expect(!session.allTabs.contains { $0 === favorite })
        #expect(session.activeSpace === second)
        session.openPinnedSite(pin)
        #expect(shared.favoriteTabs.count == 1)
        #expect(session.activeTab !== favorite)
        #expect(session.activeTab?.pinnedSiteID == pin.id)
    }

    @Test("Unfavoriting in another Space moves the page there without making another copy")
    func unpinSharedFavorite() throws {
        let session = TestSession.make().0
        let shared = try profile(session)
        let first = session.addSpace(named: "First", profile: shared)
        let favorite = session.newTab(url: URL(string: "https://favorite.invalid/")!)
        session.pin(favorite)
        let pin = try #require(shared.pinnedSites.first)
        let second = session.addSpace(named: "Second", profile: shared)
        session.openPinnedSite(pin)
        let before = session.allTabs.count
        session.removePinnedSite(pin)
        #expect(shared.pinnedSites.isEmpty && shared.favoriteTabs.isEmpty)
        #expect(second.workspaceTabs.contains { $0 === favorite })
        #expect(!first.workspaceTabs.contains { $0 === favorite })
        #expect(session.activeTab === favorite)
        #expect(session.allTabs.count == before)
    }

    @Test("Assigning a profile keeps the Space layout and URLs while discarding cross-profile WebKit state")
    func assignment() throws {
        let session = TestSession.make().0
        let space = session.activeSpace
        let initial = space.profile
        let group = session.createGroup(named: "Retained")
        let stored = SessionSnapshot.Tab(url: URL(string: "https://site.invalid/private-page")!, title: "Saved title",
            groupID: group.id, customName: "Project", interactionState: Data("old profile state".utf8), keepsInSidebar: true)
        let original = Tab(restoring: stored, identity: initial.identity)
        space.insert(original, at: 1); space.setActiveTabID(original.id)
        let target = try profile(session, "Separate")
        let id = space.id, theme = space.theme, look = space.look
        #expect(session.assignProfile(target, to: space))
        #expect(space.id == id && space.theme == theme && space.look == look)
        #expect(space.identity == target.identity)
        let selected = try #require(space.activeTab)
        #expect(selected !== original)
        #expect(selected.url == original.url && selected.groupID == group.id && selected.customName == "Project")
        #expect(selected.keepsInSidebar)
        #expect(selected.snapshot().interactionState == nil)
        #expect(selected.currentWebView == nil)
        #expect(session.profiles.contains { $0 === initial })
        #expect(!session.assignProfile(target, to: space), "Choosing the checked profile does not reload pages")
        #expect(space.activeTab === selected)
    }

    @Test("Private Spaces and foreign registries cannot be rebound to a persistent profile")
    func rejectsIncompatibleAssignments() throws {
        let session = TestSession.make().0
        let persistent = try profile(session)
        let privateSpace = session.addSpace(named: "Private", isPrivate: true)
        #expect(!session.assignProfile(persistent, to: privateSpace))
        let regular = session.spaces[0]
        #expect(!session.assignProfile(privateSpace.profile, to: regular))
        let foreign = try profile(TestSession.make().0, "Foreign")
        #expect(!session.assignProfile(foreign, to: regular))
        #expect(regular.identity == .standard)
    }

    @Test("A profile and its Favorite survive deleting its last Space and saving the session")
    func unusedProfileSurvives() throws {
        let (session, store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let shared = try profile(session)
        let space = session.addSpace(named: "Temporary layout", profile: shared)
        let favorite = session.newTab(url: URL(string: "https://favorite.invalid/retained")!)
        session.pin(favorite)
        session.removeSpace(space)
        #expect(!session.spaces.contains { $0 === space })
        #expect(session.profiles.contains { $0 === shared })
        #expect(shared.favoriteTabs.first === favorite)
        session.saveNow()
        let settings = Settings(defaults: UserDefaults(suiteName: "barc.profile-restore.\(UUID())")!)
        let restored = BrowserSession(database: nil, sessionStore: store, settings: settings)
        let profile = try #require(restored.profiles.first { $0.id == shared.id })
        #expect(profile.identity == shared.identity)
        let replacement = restored.addSpace(named: "Replacement", profile: profile)
        let pin = try #require(replacement.pinnedSites.first)
        restored.openPinnedSite(pin)
        #expect(restored.activeTab?.url == favorite.url)
        #expect(profile.favoriteTabs.count == 1)
    }

    @Test("Profile assignment does not copy or erase cookies, including in an unused old profile")
    func cookieOwnership() async throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let first = try profile(session, "Cookie A"), second = try profile(session, "Cookie B")
        let space = session.addSpace(named: "Layout", profile: first)
        let a = WebEnvironment.shared.dataStore(for: first.identity)
        let b = WebEnvironment.shared.dataStore(for: second.identity)
        let name = "profile-fixture-\(UUID())"
        let cookie = try #require(HTTPCookie(properties: [.name: name, .value: "fictional", .domain: "profile-fixture.invalid", .path: "/"]))
        await a.httpCookieStore.setCookie(cookie)
        #expect(session.assignProfile(second, to: space))
        #expect(await a.httpCookieStore.allCookies().contains { $0.name == name })
        #expect(!(await b.httpCookieStore.allCookies().contains { $0.name == name }))
        #expect(session.assignProfile(first, to: space))
        #expect(WebEnvironment.shared.dataStore(for: space.identity) === a)
        await a.httpCookieStore.deleteCookie(cookie)
        WebEnvironment.shared.releaseDataStore(for: first.identity)
        WebEnvironment.shared.releaseDataStore(for: second.identity)
    }

    @Test("Profile preferences are shared while names, themes and tab layouts remain distinct")
    func preferencesAndLayout() throws {
        let session = TestSession.make().0
        let shared = try profile(session)
        let first = session.addSpace(named: "First", theme: .amber, profile: shared)
        let second = session.addSpace(named: "Second", theme: .green, profile: shared)
        session.setDownloadsDirectoryPath("/tmp/work-downloads", for: first)
        session.setUserAgent("Profile fixture", for: first)
        session.setPasswordVaultAccount("Work vault", for: first)
        #expect(second.downloadsDirectoryPath == first.downloadsDirectoryPath)
        #expect(second.userAgent == "Profile fixture")
        #expect(second.passwordVaultAccount == "Work vault")
        #expect(first.name != second.name && first.theme != second.theme)
        let identity = shared.identity
        session.renameProfile(shared, to: "Renamed profile")
        #expect(shared.identity == identity)
        #expect(first.name == "First" && second.name == "Second")
        let snapshot = session.snapshot()
        let restored = try #require(BrowserSession.spaces(from: snapshot))
        let a = try #require(restored.first { $0.id == first.id }), b = try #require(restored.first { $0.id == second.id })
        #expect(a.profile === b.profile)
        #expect(a.profile.name == "Renamed profile" && a.userAgent == "Profile fixture")
    }

    @Test("Profile menu checkmarks and retained targets refer to the selected Space's profile")
    func menuSelection() async throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let current = session.activeSpace
        let other = session.addSpace(named: "Other")
        session.selectSpace(current)
        let sidebar = SidebarViewController(session: session)
        _ = sidebar.view
        let menu = sidebar.makeSpaceOptionsMenu(for: other, anchor: sidebar.view)
        let choices = try #require(menu.items.first { $0.title == "Set Profile" }?.submenu)
        #expect(choices.items.first { $0.title == other.profile.name }?.state == .on)
        let choice = try #require(choices.items.first { $0.title == current.profile.name })
        #expect(NSApp.sendAction(try #require(choice.action), to: choice.target, from: choice))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(other.profile === current.profile)
        #expect(session.activeSpace === current)
        #expect(choices.items.contains { $0.title == "New Profile…" })
    }

    @Test("Private Favorite URLs are absent from both Space and profile snapshots")
    func privateFavoritesNeverPersist() throws {
        let session = TestSession.make().0
        _ = session.addSpace(named: "Private", isPrivate: true)
        let tab = session.newTab(url: URL(string: "https://private-fixture.invalid/never-persist")!)
        session.pin(tab)
        let json = String(decoding: try JSONEncoder().encode(session.snapshot()), as: UTF8.self)
        #expect(!json.contains("private-fixture.invalid"))
        #expect(!json.contains("never-persist"))
    }

    @Test("A stale Favorite belonging to another profile cannot open in the current one")
    func staleFavoriteIsRejected() throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        let page = session.newTab(url: URL(string: "https://favorite.invalid/source")!)
        session.pin(page)
        let pin = try #require(source.pinnedSites.first)
        let target = session.addSpace(named: "Separate")
        let selected = target.activeTab
        let count = session.allTabs.count
        session.openPinnedSite(pin)
        #expect(target.activeTab === selected)
        #expect(session.allTabs.count == count)
        #expect(target.pinnedSites.isEmpty)
    }

    @Test("Forget-on-close waits for this profile's last page, independent of other profiles")
    func forgetOnCloseScope() throws {
        let session = TestSession.make().0
        let shared = try profile(session)
        let first = session.addSpace(named: "First", profile: shared)
        let site = URL(string: "https://profile-forget-\(UUID().uuidString.lowercased()).invalid/")!
        let host = try #require(site.host())
        SiteSettings.shared.update { $0.set("on", for: host, in: .forgetWhenClosed) }
        defer { SiteSettings.shared.update { $0.remove(host, from: .forgetWhenClosed) } }
        // A page in another profile does not keep this profile's data alive.
        let other = session.addSpace(named: "Separate")
        session.newTab(url: site)
        #expect(session.identityToForgetAfterClosing(site, in: first) == shared.identity)
        // Any page in a second layout sharing the profile does keep it alive.
        session.addSpace(named: "Shared layout", profile: shared)
        session.newTab(url: site)
        #expect(session.identityToForgetAfterClosing(site, in: first) == nil)
        #expect(session.identityToForgetAfterClosing(site, in: other) == nil)
    }

    @Test("Clearing a shared profile's website data leaves other profiles signed in")
    func clearProfileScope() async throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let a = try profile(session, "Clear A"), b = try profile(session, "Keep B")
        let first = session.addSpace(named: "First", profile: a)
        let second = session.addSpace(named: "Second", profile: a)
        let aStore = WebEnvironment.shared.dataStore(for: a.identity)
        let bStore = WebEnvironment.shared.dataStore(for: b.identity)
        let cookie = try #require(HTTPCookie(properties: [.name: "profile-clear-fixture", .value: "fictional", .domain: "profile-clear.invalid", .path: "/"]))
        await aStore.httpCookieStore.setCookie(cookie)
        await bStore.httpCookieStore.setCookie(cookie)
        await session.clearSpaceData(for: first)
        #expect(!(await aStore.httpCookieStore.allCookies().contains { $0.name == cookie.name }))
        #expect(await bStore.httpCookieStore.allCookies().contains { $0.name == cookie.name })
        #expect(WebEnvironment.shared.dataStore(for: second.identity) === aStore)
        session.removeSpace(second)
        session.removeSpace(first)
        #expect(session.storedIdentities.contains(a.identity), "Unused profiles stay in browsing-data management")
        await bStore.httpCookieStore.deleteCookie(cookie)
        WebEnvironment.shared.releaseDataStore(for: a.identity)
        WebEnvironment.shared.releaseDataStore(for: b.identity)
    }

    @Test("The Settings profile chooser keeps duplicate names distinct and does not switch the active Space")
    func settingsProfileChooser() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let a = try profile(session, "Same name"), b = try profile(session, "Same name")
        let current = session.activeSpace
        let edited = session.addSpace(named: "Edited", profile: a)
        session.selectSpace(current)
        let pane = SpacesSettingsViewController(session: session)
        let view = pane.view
        pane.select(edited)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let chooser = try #require(descendants(view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Browsing profile" })
        #expect(chooser.itemArray.filter { $0.title == "Same name" }.count == 2)
        let choice = try #require(chooser.itemArray.first { $0.representedObject as? UUID == b.id })
        chooser.select(choice)
        #expect(NSApp.sendAction(try #require(chooser.action), to: chooser.target, from: chooser))
        #expect(edited.profile === b && session.activeSpace === current)
        session.renameProfile(b, to: "Renamed")
        #expect(chooser.titleOfSelectedItem == "Renamed")
        let privateSpace = session.addSpace(named: "Private", isPrivate: true)
        pane.select(privateSpace)
        #expect(!chooser.isEnabled)
        #expect(chooser.numberOfItems == 1)
    }

    @Test("Moving within a profile keeps the same page; crossing profiles clears opaque state")
    func movingBetweenLayouts() throws {
        let session = TestSession.make().0
        let shared = try profile(session)
        let first = session.addSpace(named: "First", profile: shared)
        let stored = SessionSnapshot.Tab(url: URL(string: "https://move-fixture.invalid/")!,
            customName: "Preserved", interactionState: Data("profile-scoped history state".utf8), keepsInSidebar: true)
        let page = Tab(restoring: stored, identity: shared.identity)
        first.insert(page, at: 1)
        let second = session.addSpace(named: "Second", profile: shared)
        session.move(page, toSpace: second)
        #expect(!first.workspaceTabs.contains { $0 === page })
        #expect(second.workspaceTabs.contains { $0 === page })
        #expect(page.snapshot().interactionState == stored.interactionState)
        let separate = session.addSpace(named: "Separate")
        session.move(page, toSpace: separate)
        let moved = try #require(separate.workspaceTabs.first { $0.url == stored.url })
        #expect(moved !== page && moved.identity == separate.identity)
        #expect(moved.snapshot().interactionState == nil)
        #expect(moved.customName == "Preserved" && moved.keepsInSidebar)
    }

    @Test("Changing profiles strips old state from closed and archived pages while retaining URLs")
    func restoresDoNotCrossProfiles() throws {
        let session = TestSession.make().0
        let space = session.activeSpace
        func page(_ path: String) -> Tab {
            let stored = SessionSnapshot.Tab(url: URL(string: "https://restore-fixture.invalid/" + path)!,
                interactionState: Data("old profile history".utf8))
            let tab = Tab(restoring: stored, identity: space.identity)
            space.insert(tab, at: space.workspaceTabs.count)
            return tab
        }
        let closed = page("closed"), archived = page("archived")
        session.closeTab(closed)
        session.archive([archived])
        #expect(session.assignProfile(try profile(session), to: space))
        let reopened = try #require(session.reopenClosedTab())
        #expect(reopened.url == closed.url && reopened.snapshot().interactionState == nil)
        let record = try #require(session.archivedTabs(in: space).first)
        #expect(record.snapshot.url == archived.url && record.snapshot.interactionState == nil)
    }

    @Test("Arc Spaces sharing a profile merge Favorites once and repeated imports add nothing")
    func sharedArcFavorites() throws {
        let session = TestSession.make().0
        let identity = Space.Identity.makeIsolated()
        let url = URL(string: "https://shared-arc-fixture.invalid/")!
        func stored(_ name: String, _ source: String) -> SessionSnapshot.Space {
            let pin = UUID()
            return .init(id: UUID(), name: name,
                tabs: [.init(url: url, pinnedSiteID: pin, importedSourceID: source)], activeTabIndex: 0,
                profileName: "Arc profile", identity: identity,
                pinnedSites: [.init(id: pin, url: url, title: "Shared Favorite")])
        }
        let first = stored("First", "first-favorite"), second = stored("Second", "second-favorite")
        _ = try session.applyArcSpaces([first, second])
        let a = try #require(session.spaces.first { $0.id == first.id })
        let b = try #require(session.spaces.first { $0.id == second.id })
        #expect(a.profile === b.profile)
        #expect(a.profile.favoriteTabs.count == 1 && a.pinnedSites.count == 1)
        #expect(a.activeTab === b.activeTab)
        let before = session.allTabs.count
        let repeated = try session.applyArcSpaces([first, second])
        #expect(repeated.tabs == 0 && repeated.favorites == 0)
        #expect(session.allTabs.count == before)
    }

    @Test("Merging old copies of a Favorite preserves a divergent page and its notes")
    func divergentArcFavorite() throws {
        let session = TestSession.make().0
        let identity = Space.Identity.makeIsolated()
        let home = URL(string: "https://divergent-arc-fixture.invalid/")!
        let pinA = UUID(), pinB = UUID()
        let first = SessionSnapshot.Space(id: UUID(), name: "First", tabs: [.init(url: home, pinnedSiteID: pinA, importedSourceID: "favorite-a")], activeTabIndex: 0,
            identity: identity, pinnedSites: [.init(id: pinA, url: home, title: "Favorite")])
        let page = URL(string: "https://divergent-arc-fixture.invalid/keep-page")!
        let second = SessionSnapshot.Space(id: UUID(), name: "Second", tabs: [.init(url: page, pinnedSiteID: pinB, note: "Keep these notes", importedSourceID: "favorite-b")], activeTabIndex: 0,
            identity: identity, pinnedSites: [.init(id: pinB, url: home, title: "Favorite")])
        _ = try session.applyArcSpaces([first, second])
        let b = try #require(session.spaces.first { $0.id == second.id })
        #expect(b.profile.favoriteTabs.count == 1)
        let preserved = try #require(b.workspaceTabs.first { $0.url == page })
        #expect(preserved.note == "Keep these notes" && preserved.pinnedSiteID == nil)
        #expect(b.activeTab === preserved)
        #expect(try session.applyArcSpaces([first, second]).tabs == 0)
    }
}
