// Modified for Barc: Favorite units expose a profile-owned icon picker, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Favorite unit icons", .serialized)
@MainActor
struct FavoriteIconTests {
    private func fixture() -> (BrowserSession,[Tab]) {
        let session = TestSession.make().0
        let pages = (0..<2).map { index in
            let page = session.newTab(url:URL(string:"https://favorite-icon.invalid/\(index)")!)
            session.rename(page,to:"Pane \(index)")
            return page
        }
        session.splitTabs(pages);session.pin(pages[0])
        return (session,pages)
    }

    @Test("A Favorite split tile offers Change Icon and opens the shared glyph picker",arguments:[false,true])
    func nativePicker(refresh:Bool) async throws {
        _ = NSApplication.shared
        let (session,pages) = fixture()
        let layout = session.activeSplit,selected = session.activeTab?.id
        let profile = session.activeSpace.profile
        let sidebar = SidebarViewController(session:session)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:228,height:760),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil);window.close() }
        let host = UITestSupport.host(sidebar.view,width:228,height:760)
        window.contentView = host;host.layoutSubtreeIfNeeded()
        window.alphaValue = 0;window.orderFront(nil)
        let title = try #require(session.activeSpace.pinnedSites.first?.title)
        let tile = try #require(UITestSupport.descendants(of:host).first { $0.accessibilityLabel() == title })
        let event = try #require(NSEvent.mouseEvent(with:.rightMouseDown,location:.zero,modifierFlags:[],timestamp:0,
            windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        let menu = try #require(tile.menu(for:event))
        let item = try #require(menu.items.first { $0.title == "Change Icon…" })
        #expect(item.isEnabled)
        #expect(NSApp.sendAction(try #require(item.action),to:item.target,from:item))
        if refresh { session.changes.send(.structure) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        // Other window suites can dismiss a transient popover before this
        // continuation resumes. Inspect this sidebar's retained presentation,
        // never a different fixture's controller in the application window list.
        let palette = try #require(sidebar.tabIconPopover?.contentViewController as? CompactSpaceIconPicker)
        #expect(palette.view.accessibilityLabel() == "Favorite icon")
        palette.searchFor("🐮");palette.chooseItem(at:0)
        #expect(profile.pinnedSites.first?.icon == .emoji("🐮"))
        #expect(session.activeSplit == layout && session.activeTab?.id == selected)
        #expect(pages.allSatisfy { $0.currentWebView == nil && $0.sidebarIcon == .automatic })
        host.layoutSubtreeIfNeeded()
        let changed = try #require(UITestSupport.descendants(of:host).first { $0.accessibilityLabel() == title })
        let artwork = try #require(UITestSupport.descendants(of:changed).compactMap { $0 as? NSImageView }.first { !$0.isHidden && $0.image != nil })
        #expect(artwork.bounds.size == NSSize(width:16,height:16))
        #expect(changed.hitTest(NSPoint(x:changed.frame.midX,y:changed.frame.midY)) === changed)
        // Other suites create windows between main-queue turns. Exercise the
        // shared reset action in an owned controller rather than relying on a
        // second transient popover remaining visible across those turns.
        let siteID = try #require(profile.pinnedSites.first).id
        let resetPicker = CompactSpaceIconPicker(selected:.emoji("🐮"),label:"Favorite icon") { icon in
            session.setFavoriteIcon(icon,for:siteID,in:profile)
        }
        let reset = try #require(UITestSupport.descendants(of:resetPicker.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Remove Icon" && !$0.isHidden })
        #expect(NSApp.sendAction(try #require(reset.action),to:reset.target,from:reset))
        #expect(profile.pinnedSites.first?.icon == .automatic)
        #expect(session.snapshot().profiles?.first { $0.id == profile.id }?.pinnedSites?.first?.icon == nil)
    }

    @Test("The profile icon is shared, saved and retained by an unpinned split")
    func lifecycle() throws {
        let (session,pages) = fixture(),owner = session.activeSpace
        let site = try #require(owner.pinnedSites.first)
        let original = try #require(owner.splits.layout(containing:pages[0].id))
        let sibling = session.addSpace(named:"Sibling",profile:owner.profile)
        session.openPinnedSite(site)
        #expect(session.setFavoriteIcon(.emoji("🐮"),for:site.id,in:owner.profile))
        #expect(owner.pinnedSites.first?.icon == .emoji("🐮") && sibling.pinnedSites.first?.icon == .emoji("🐮"))
        #expect(owner.splits.icon(containing:pages[0].id) == .emoji("🐮"))
        let saved = session.snapshot(),reopened = TestSession.make().0
        reopened.mergeSnapshot(saved)
        let restored = try #require(reopened.spaces.first { $0.id == sibling.id })
        reopened.selectSpace(restored)
        let destination = try #require(restored.pinnedSites.first)
        #expect(destination.icon == .emoji("🐮"))
        reopened.openPinnedSite(destination)
        #expect(restored.splits.icon(containing:try #require(reopened.activeTab).id) == .emoji("🐮"))
        session.removePinnedSite(site)
        #expect(sibling.splits.layout(containing:pages[0].id) == original)
        #expect(sibling.splits.icon(containing:pages[0].id) == .emoji("🐮"))
        session.pin(pages[0])
        #expect(sibling.pinnedSites.first?.icon == .emoji("🐮"))
    }

    @Test("A captured single Favorite unpins using its latest icon")
    func staleSingle() throws {
        let session = TestSession.make().0
        let tab = session.newTab(url:URL(string:"https://single-icon.invalid")!)
        tab.setSidebarIcon(.symbol("ionicon.planet"));session.pin(tab)
        let stale = try #require(session.activeSpace.pinnedSites.first)
        #expect(stale.icon == .symbol("ionicon.planet"))
        session.setFavoriteIcon(.emoji("🐮"),for:stale.id,in:session.activeSpace.profile)
        session.removePinnedSite(stale)
        #expect(tab.sidebarIcon == .emoji("🐮") && tab.pinnedSiteID == nil)
        session.pin(tab)
        #expect(session.activeSpace.pinnedSites.first?.icon == .emoji("🐮"))
    }

    @Test("Icon updates keep their profile target after switching Spaces and reject removed targets")
    func ownership() throws {
        let (session,_) = fixture(),profile = session.activeSpace.profile
        let site = try #require(profile.pinnedSites.first)
        let other = try #require(session.addProfile(named:"Other"))
        _ = session.addSpace(named:"Other",profile:other)
        #expect(session.setFavoriteIcon(.emoji("🐮"),for:site.id,in:profile))
        #expect(profile.pinnedSites.first?.icon == .emoji("🐮") && other.pinnedSites.isEmpty)
        let foreign = BrowserProfile(name:"Foreign",identity:.isolated(UUID()))
        #expect(!session.setFavoriteIcon(.emoji("🐮"),for:site.id,in:foreign))
        profile.removePinnedSite(site)
        #expect(!session.setFavoriteIcon(.emoji("🐮"),for:site.id,in:profile))
    }

    @Test("Split icons survive copy and save bindings; resetting omits the optional field")
    func splitBindings() throws {
        let ids = [UUID(),UUID()],copies = [UUID(),UUID()]
        var source = SplitCollection()
        let joined = source.join(ids,grid:.sideBySide)
        #expect(joined)
        source.setIcon(.symbol("ionicon.planet"),containing:ids[0])
        var copied = SplitCollection()
        copied.copyCompleteGroups(from:source,mapping:Dictionary(uniqueKeysWithValues:zip(ids,copies)))
        #expect(copied.icon(containing:copies[1]) == .symbol("ionicon.planet"))
        let records = try #require(copied.snapshot(tabIDs:copies))
        var restored = SplitCollection.restoring(records,tabIDs:ids)
        #expect(restored.icon(containing:ids[0]) == .symbol("ionicon.planet"))
        restored.setIcon(.automatic,containing:ids[1])
        let clean = try #require(restored.snapshot(tabIDs:ids))
        #expect(!String(decoding:try JSONEncoder().encode(clean),as:UTF8.self).contains("icon"))
        #expect(try JSONDecoder().decode([SessionSnapshot.Split].self,from:JSONEncoder().encode(clean)) == clean)
        restored.dissolve(containing:ids[0])
        #expect(restored.icon(containing:ids[1]) == .automatic)
    }

    @Test("Private icons and Favorite destinations never enter a saved session")
    func privateIcons() throws {
        let session = TestSession.make().0
        let owner = session.addSpace(named:"Private",isPrivate:true)
        let page = session.newTab(url:URL(string:"https://private-icon.invalid")!)
        session.pin(page)
        let site = try #require(owner.pinnedSites.first)
        session.setFavoriteIcon(.emoji("🦄"),for:site.id,in:owner.profile)
        let text = String(decoding:try JSONEncoder().encode(session.snapshot()),as:UTF8.self)
        #expect(!text.contains("private-icon.invalid") && !text.contains("🦄"))
    }

    @Test("Custom artwork uses the existing well in both appearances and missing artwork falls back",
          arguments:["🐮","ionicon.planet","missing-symbol","missing-file"])
    func artwork(_ value:String) throws {
        let choice:SpaceIcon = value == "🐮" ? .emoji(value):(value == "missing-file" ? .custom(value):.symbol(value))
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            let strip = PinnedTilesView()
            strip.appearance = NSAppearance(named:appearance)
            strip.show([.init(id:"fixture",title:"Fixture",icon:choice)])
            let host = UITestSupport.host(strip,width:212,height:44)
            host.layoutSubtreeIfNeeded()
            let tile = try #require(UITestSupport.descendants(of:strip).first { $0.accessibilityLabel() == "Fixture" })
            let custom = UITestSupport.descendants(of:tile).compactMap { $0 as? NSImageView }.filter { !($0 is FaviconImageView) && !$0.isHidden }
            if value.hasPrefix("missing") { #expect(custom.isEmpty) }
            else {
                let image = try #require(custom.first)
                #expect(image.image != nil && image.bounds.size == NSSize(width:16,height:16))
            }
        }
    }

    @Test("A profile without Spaces retains its icon across a real session-file reopen")
    func unusedProfile() throws {
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        let profile = try #require(session.addProfile(named:"Detached"))
        let owner = session.addSpace(named:"Temporary",profile:profile)
        let page = session.newTab(url:URL(string:"https://detached-icon.invalid")!)
        session.pin(page)
        let site = try #require(profile.pinnedSites.first)
        session.setFavoriteIcon(.symbol("ionicon.planet"),for:site.id,in:profile)
        session.removeSpace(owner);session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"favorite-icons.\(UUID())")!)
        settings.restoresSession = true
        let restored = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let saved = try #require(restored.profiles.first { $0.id == profile.id })
        #expect(saved.pinnedSites.first?.icon == .symbol("ionicon.planet"))
    }

    @Test("A stale rendered tile cannot remove a same-ID destination in another profile")
    func staleTile() throws {
        let (session,_) = fixture(),owner = session.activeSpace
        let site = try #require(owner.pinnedSites.first)
        let sidebar = SidebarViewController(session:session)
        let host = UITestSupport.host(sidebar.view,width:228,height:760)
        let strip = try #require(UITestSupport.descendants(of:host).compactMap { $0 as? PinnedTilesView }.first)
        let oldID = "\(owner.id)/\(owner.profile.id)/\(site.id)"
        let other = try #require(session.addProfile(named:"Other"))
        other.addPinnedSite(site)
        _ = session.addSpace(named:"Other",profile:other)
        strip.onRemove?(oldID);strip.onSelect?(oldID)
        #expect(other.pinnedSites.count == 1 && owner.pinnedSites.count == 1)
    }

    @Test("Archiving and restoring an unpinned group keeps its unit icon")
    func archiveIcon() throws {
        let (session,pages) = fixture(),owner = session.activeSpace
        let site = try #require(owner.pinnedSites.first)
        session.setFavoriteIcon(.emoji("🐮"),for:site.id,in:owner.profile)
        session.removePinnedSite(site);session.archive(pages)
        let restored = session.restoreAllArchived(in:owner)
        #expect(restored.count == 2)
        #expect(owner.splits.icon(containing:try #require(restored.first).id) == .emoji("🐮"))
    }
}
