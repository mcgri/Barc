// Modified for Barc: combined sidebar batch regression checks, 2026-10-25.
import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Sidebar batch", .serialized)
@MainActor
struct SidebarBatchTests {
    private func rows(_ count:Int) -> [CommandResult] {
        CommandRanker.rank(query:"example",tabs:[],history:(0..<count).map {
            HistoryCandidate(url:URL(string:"https://example.invalid/\($0)")!,title:"Example \($0)",key:"example.invalid/\($0)",visitCount:1)
        },limit:count)
    }
    private func page(_ session:BrowserSession,_ index:Int) -> Tab {
        let tab = session.newTab(url:URL(string:"https://batch.invalid/\(index)")!)
        session.rename(tab,to:"Pane \(index)");return tab
    }

    @Test("All centered entry modes keep the input fixed through changing results",arguments:[0,1,2])
    func stableInput(mode:Int) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;defer { window.close() }
        let host = try #require(window.contentView)
        let bar = CommandBar();bar.install(in:host)
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            host.appearance = NSAppearance(named:appearance)
            switch mode {
            case 0:bar.openNewTab(recentResults:rows(4))
            case 1:bar.openLocation(text:"https://example.invalid",suggestions:rows(4))
            default:bar.openSplit(recentResults:rows(4))
            }
            host.layoutSubtreeIfNeeded()
            let field = try #require(UITestSupport.descendants(of:bar).compactMap { $0 as? NSTextField }.first { $0.isEditable })
            let before = field.convert(field.bounds,to:host)
            let panelBefore = try #require(bar.subviews.first).frame
            let boundsBefore = bar.bounds
            for count in [0,8,2,1,8,0,4] {
                bar.setResults(rows(count));host.layoutSubtreeIfNeeded()
                let after = field.convert(field.bounds,to:host)
                #expect(abs(after.midY-before.midY)<0.5 && abs(after.midX-before.midX)<0.5,"Mode \(mode), \(appearance), count \(count): before \(before), after \(after), panelBefore \(panelBefore), panelAfter \(bar.subviews.first!.frame), boundsBefore \(boundsBefore), after \(bar.bounds)")
                #expect(host.bounds.contains(try #require(bar.subviews.first).frame))
                #expect(bar.frame == host.bounds && bar.fieldHasFocus)
            }
            bar.close()
        }
    }

    @Test("Pending queries retain their rows but cannot submit or hover an obsolete destination")
    func pendingQuery() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;defer { window.close() }
        let bar = CommandBar();bar.install(in:try #require(window.contentView))
        bar.resultsProvider = { _ in try? await Task.sleep(for:.milliseconds(500));return [] }
        bar.openNewTab(recentResults:rows(4))
        let text = try #require(window.firstResponder as? NSTextView)
        text.insertText("replacement.invalid/path",replacementRange:NSRange(location:NSNotFound,length:0))
        #expect(bar.visibleResults.count == 4 && bar.selectedIndex == nil)
        bar.moveSelection(by:1)
        #expect(bar.selectedIndex == nil && bar.queryText == "replacement.invalid/path")
        var action:CommandAction?
        bar.onRun = { action = $0;_ = $1;_ = $2 }
        bar.submit()
        #expect(action == .openURL(URL(string:"https://replacement.invalid/path")!))
    }

    @Test("Same-profile Favorites rank once and address prefixes ignore the Space subtitle")
    func ranking() throws {
        let id = UUID(),url = URL(string:"https://example.invalid/docs")!
        let candidate = TabCandidate(id:id,title:"Reference",address:"example.invalid/docs",url:url,isActive:false,spaceName:"Work")
        let ranked = CommandRanker.rank(query:"exam",tabs:[candidate,candidate],history:[])
        #expect(ranked.count == 1 && ranked.first?.action == .switchToTab(id))
        #expect(ranked.first?.completionText == "example.invalid/docs")
    }

    @Test("Named split rendering, numbering, transfer and detach preserve the complete unit")
    func namedUnit() throws {
        let session = TestSession.make().0,source = session.activeSpace
        let a = page(session,1),b = page(session,2)
        session.splitTabs([a,b]);session.selectTab(b)
        #expect(session.renameSplit(containing:a.id,in:source,to:"  Research pair  "))
        #expect(session.setSplitIcon(.emoji("📚"),containing:a.id,in:source))
        let sidebar = SidebarViewController(session:session)
        let host = UITestSupport.host(sidebar.view,width:228,height:800)
        host.layoutSubtreeIfNeeded()
        let row = try #require(sidebar.tabListTableView.view(atColumn:0,row:sidebar.tabListTableView.selectedRow,makeIfNecessary:true) as? SplitRowView)
        #expect(row.isNamed && row.members.allSatisfy(\.isHidden))
        #expect(source.sidebarNavigationTabs.filter { [a.id,b.id].contains($0.id) }.map(\.id) == [b.id])
        let menu = sidebar.makeRowMenu(at:sidebar.tabListTableView.selectedRow)
        #expect(menu.items.contains { $0.title == "Rename…" })
        #expect(menu.items.contains { $0.title == "Tabs" && $0.submenu?.items.count == 2 })
        let target = session.addSpace(named:"Destination",profile:source.profile)
        let copied = session.receiveSidebarTabs([a],from:source,into:target,copy:true)
        #expect(copied.count == 2 && source.splits.layout(containing:a.id) != nil)
        #expect(target.splits.name(containing:copied[0].id) == "Research pair")
        #expect(target.splits.icon(containing:copied[0].id) == .emoji("📚"))
        #expect(copied.map(\.customName) == ["Pane 1","Pane 2"])
        #expect(session.detachSplitPane(copied[0],in:target))
        #expect(target.tabs.contains { $0 === copied[0] } && target.tabs.contains { $0 === copied[1] })
        #expect(target.splits.layout(containing:copied[0].id) == nil)
        #expect(session.renameSplit(containing:a.id,in:source,to:""))
        #expect(source.splits.name(containing:a.id) == nil && a.customName == "Pane 1")
    }

    @Test("Split menu rename opens after tracking and still targets the original unit")
    func menuRename() async throws {
        _ = NSApplication.shared
        let session = TestSession.make().0,owner = session.activeSpace
        let a = page(session,1),b = page(session,2)
        session.splitTabs([a,b]);session.renameSplit(containing:a.id,in:owner,to:"Research")
        let sidebar = SidebarViewController(session:session)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:228,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;defer { window.close() }
        let host = UITestSupport.host(sidebar.view,width:228,height:800)
        sidebar.view.bottomAnchor.constraint(equalTo:host.bottomAnchor).isActive = true
        window.contentView = host;host.layoutSubtreeIfNeeded()
        let menu = sidebar.makeRowMenu(at:sidebar.tabListTableView.selectedRow)
        let item = try #require(menu.items.first { $0.title == "Rename…" })
        #expect(NSApp.sendAction(try #require(item.action),to:item.target,from:item))
        #expect(!UITestSupport.descendants(of:sidebar.view).contains { $0 is FolderNameEditor })
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        let field = try #require(UITestSupport.descendants(of:sidebar.view).compactMap { $0 as? FolderNameEditor }.first)
        #expect(field.stringValue == "Research" && field.accessibilityLabel() == "Split name")
        field.stringValue = "Committed from menu";field.commit()
        #expect(owner.splits.name(containing:a.id) == "Committed from menu")
        #expect(a.customName == "Pane 1" && b.customName == "Pane 2")
    }

    @Test("A Favorite rename belongs to its profile and updates sibling split layouts")
    func favoriteName() throws {
        let session = TestSession.make().0,source = session.activeSpace
        let a = page(session,1),b = page(session,2)
        session.splitTabs([a,b]);session.pin(a)
        let id = try #require(source.pinnedSites.first?.id)
        let sibling = session.addSpace(named:"Sibling",profile:source.profile)
        session.openPinnedSite(try #require(source.pinnedSites.first))
        #expect(session.setFavoriteName("Project",for:id,in:source.profile))
        #expect(source.profile.pinnedSites.first?.title == "Project")
        #expect(source.splits.name(containing:a.id) == "Project")
        #expect(sibling.splits.name(containing:a.id) == "Project")
        let foreign = session.addSpace(named:"Foreign")
        #expect(!session.setFavoriteName("Wrong",for:id,in:foreign.profile))
        #expect(source.profile.pinnedSites.first?.title == "Project")
    }

    @Test("Option actions retain their handler after menu construction")
    func retainedOptions() throws {
        var changes:[LiveFolderOptionChange] = []
        let menu = LiveFolderOptionsMenu.menu(for:[.toggle(key:"pause",title:"Pause",isOn:false),.submenu(title:"Nested",items:[.action(key:"refresh",title:"Refresh")])]) { changes.append($0) }
        let first = try #require(menu.items.first)
        _ = NSApplication.shared
        #expect(NSApp.sendAction(try #require(first.action),to:first.target,from:first))
        let nested = try #require(menu.items.last?.submenu?.items.first)
        #expect(NSApp.sendAction(try #require(nested.action),to:nested.target,from:nested))
        #expect(changes.map(\.key) == ["pause","refresh"])
    }

    @Test("Profile-session folders fail closed without an authenticated fetcher and preserve pause")
    func profileFetch() async throws {
        let store = LiveFolderStore(fileURL:FileManager.default.temporaryDirectory.appending(path:"batch-live-\(UUID()).json"))
        let manager = LiveFolderManager(store:store);defer { manager.stop() }
        let id = UUID()
        manager.add(folderID:id,source:.github(.init(login:"tester",useProfileSession:true)))
        manager.apply(.init(key:LiveFolderOptionChange.pauseKey,value:.bool(true)),to:id)
        await manager.refresh(folderID:id)
        #expect(manager.status(for:id,itemCount:0) == .failed(.authenticationRequired))
        #expect(manager.record(for:id)?.state.paused == true)
        let saved = try JSONEncoder().encode(try #require(manager.record(for:id)))
        #expect(try JSONDecoder().decode(LiveFolderRecord.self,from:saved).state.paused == true)
        var old = try #require(JSONSerialization.jsonObject(with:saved) as? [String:Any])
        var state = try #require(old["state"] as? [String:Any]);state.removeValue(forKey:"paused");old["state"] = state
        #expect(try JSONDecoder().decode(LiveFolderRecord.self,from:JSONSerialization.data(withJSONObject:old)).state.paused == nil)
        await store.removeAll()
    }

    @Test("The real GitHub parser reads the observed payload and rejects partial or signed-out results")
    func githubPayload() async throws {
        let config = WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame:NSRect(x:0,y:0,width:500,height:500),configuration:config)
        let html = "<meta name='user-login' content='tester'><script data-target='react-app.embeddedData'>{\"payload\":{\"blackbirdSearchRoute\":{\"results\":[{\"repo\":{\"repository\":{\"owner_login\":\"org\",\"name\":\"project\"}},\"number\":12,\"issue\":{\"issue\":{\"pull_request_id\":42}},\"hl_title\":\"Fix &amp; improve\",\"author_name\":\"tester\",\"reviewable_state\":\"draft\"}],\"result_count\":1,\"page_count\":1,\"logged_in\":true,\"errors\":[]}}}</script>"
        // Set a local document directly, with no network or user's website store.
        _ = try await webView.evaluateJavaScript("document.open();document.write(\(String(data:try JSONEncoder().encode(html),encoding:.utf8)!));document.close();")
        let value = try #require(try await webView.evaluateJavaScript(GitHubProfileFetcher.extractionScript) as? String)
        let result = try JSONDecoder().decode(GitHubProfileFetcher.Page.self,from:Data(value.utf8))
        #expect(result.valid && result.authenticated && result.login == "tester")
        #expect(result.items.first?.url.absoluteString == "https://github.com/org/project/pull/12")
        #expect(result.items.first?.title == "Fix & improve" && result.items.first?.draft == true)
        _ = try await webView.evaluateJavaScript("document.querySelector('meta').remove();document.querySelector('script').textContent = '{}';")
        let invalid = try #require(try await webView.evaluateJavaScript(GitHubProfileFetcher.extractionScript) as? String)
        let rejected = try JSONDecoder().decode(GitHubProfileFetcher.Page.self,from:Data(invalid.utf8))
        #expect(!rejected.valid && !rejected.authenticated)
    }
}
