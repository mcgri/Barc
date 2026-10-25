// Modified for Barc: one combined destination and visual-order verification batch, 2026-10-25.
import AppKit
import Foundation
import Testing
@testable import Barc

@Suite("Provider website destinations")
struct SearchDestinationTests {
    @Test("Navigation metadata supplies a direct website and its description, while queries remain searches")
    func navigation() throws {
        let data = Data(#"["portal",["portal login","https://portal.example/"],["","Portal home"],[],{"google:suggesttype":["QUERY","NAVIGATION"]}]"#.utf8)
        let predictions = SearchSuggestions.decodeResults(data,query:"portal")
        let destination = URL(string:"https://portal.example/")!
        #expect(predictions == [.query("portal login"),.navigation(destination,title:"Portal home")])
        let literal = try #require(CommandSearch.row(query:"portal",engine:.google))
        let rows = CommandSearch.addingResults(predictions,query:"portal",engine:.google,completionPrefix:"g ",to:[literal])
        #expect(rows[0] == literal)
        #expect(rows[1].kind == .search && rows[1].completionText == "g portal login")
        #expect(rows[1].action == .openURL(SearchEngine.google.url(for:"portal login")!))
        #expect(rows[2].kind == .address && rows[2].title == "Portal home" && rows[2].symbolName == "globe")
        #expect(rows[2].completionText == "portal.example" && rows[2].action == .openURL(destination))
    }

    @Test("Unsafe or malformed provider navigation never becomes an executable destination")
    func unsafeNavigation() {
        let addresses = ["javascript:alert(1)","file:///private/test","data:text/html,test","https://user:password@example.com/","https://","not a website"]
        for address in addresses {
            let payload:[Any] = ["portal",[address],[],[],["google:suggesttype":["NAVIGATION"]]]
            let data = try! JSONSerialization.data(withJSONObject:payload)
            #expect(SearchSuggestions.decodeResults(data,query:"portal").isEmpty)
        }
        let data = Data(#"["portal",["https://portal.example/"],["bad\ncaption"],[],{"google:suggesttype":["PERSONALIZED_NAVIGATION"]}]"#.utf8)
        #expect(SearchSuggestions.decodeResults(data,query:"portal") == [.navigation(URL(string:"https://portal.example/")!,title:"")])
    }

    @Test("A provider website already represented by a local tab or history row is not repeated")
    func deduplicatedWebsites() {
        let id = UUID(),url = URL(string:"https://www.portal.example/")!
        let tab = CommandResult(id:"tab",kind:.openTab,title:"Portal",subtitle:"",symbolName:"globe",action:.switchToTab(id),score:120)
        let predictions:[SearchPrediction] = [.navigation(URL(string:"http://portal.example")!,title:"Portal"),.query("portal login")]
        let rows = CommandSearch.addingResults(predictions,query:"portal",engine:.google,openTabs:[id:url],to:[tab])
        #expect(rows.count == 2 && rows[0] == tab && rows[1].kind == .search)
        let page = CommandResult(id:"history",kind:.history,title:"Portal",subtitle:"",symbolName:"clock",action:.openURL(url),score:100)
        #expect(CommandSearch.addingResults(predictions,query:"portal",engine:.google,to:[page]).count == 2)
    }

    @Test("A named Space has the observed Focus action before its similarly named website")
    func focusSpace() {
        let id = UUID(),tabID = UUID(),url = URL(string:"https://project.example/")!
        let results = CommandRanker.rank(query:"project",tabs:[.init(id:tabID,title:"Project home",address:"project.example",url:url,isActive:false)],
            spaces:[.init(id:id,name:"project.example",isActive:true,tabCount:2)],history:[])
        #expect(results.first?.title == "Focus on project.example" && results.first?.action == .switchToSpace(id))
        #expect(CommandRanker.rank(query:"focus on project",tabs:[],spaces:[.init(id:id,name:"project.example",isActive:true)],history:[]).first?.action == .switchToSpace(id))
    }
}

@Suite("Sidebar destination order", .serialized)
@MainActor
struct SidebarDestinationTests {
    private func fixture() -> (BrowserSession,Settings) {
        let defaults = UserDefaults(suiteName:"barc.destination-tests.\(UUID())")!
        let settings = Settings(defaults:defaults)
        let store = SessionStore(fileURL:FileManager.default.temporaryDirectory.appending(path:"barc-destination-tests-\(UUID()).json"))
        return (BrowserSession(database:nil,sessionStore:store,settings:settings,searchSuggestions:nil),settings)
    }
    private func page(_ name:String,in session:BrowserSession) -> Tab {
        let tab = session.newTab(url:URL(string:"https://\(name).example/")!);session.rename(tab,to:name);return tab
    }

    @Test("Cycling follows displayed ranks instead of creation order and visits a split only once")
    func visualCycle() {
        let (session,_) = fixture(),space = session.activeSpace
        let a = page("A",in:session),b = page("B",in:session),c = page("C",in:session),d = page("D",in:session)
        session.splitTabs([b,c]);session.selectTab(c)
        a.sidebarPosition = 30;b.sidebarPosition = 10;c.sidebarPosition = 10;d.sidebarPosition = 20
        #expect(space.sidebarNavigationTabs.map(\.id) == [c.id,d.id,a.id])
        session.selectTab(c);session.selectTab(offsetBy:1);#expect(session.activeTab === d)
        session.selectTab(offsetBy:1);#expect(session.activeTab === a)
        session.selectTab(offsetBy:1);#expect(session.activeTab === c)
        session.selectTab(offsetBy:-1);#expect(session.activeTab === a)
    }

    @Test("Numbered menus, checked units and selection share Favorites plus visible split order")
    func numberedMenu() throws {
        let (session,settings) = fixture(),space = session.activeSpace
        let favorite = PinnedSite(url:URL(string:"https://favorite.example/")!,title:"Favorite")
        space.addPinnedSite(favorite)
        let a = page("A",in:session),b = page("B",in:session),c = page("C",in:session)
        session.splitTabs([b,c]);session.selectTab(c)
        _ = session.renameSplit(containing:b.id,in:space,to:"Research pair")
        a.sidebarPosition = 30;b.sidebarPosition = 10;c.sidebarPosition = 10
        let menu = NSMenu(),delegate = WindowListMenu(kind:.tabs,session:session)
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["Favorite","Research pair","A"])
        #expect(menu.items.map(\.keyEquivalent) == ["1","2","3"])
        #expect(menu.items.map(\.state) == [.off,.on,.off])
        #expect(space.tab(forPin:favorite.id) == nil)
        session.selectTab(number:1);#expect(session.activeTab?.pinnedSiteID == favorite.id)
        session.selectTab(number:2);#expect(session.activeTab === c)
        settings.includesFavoritesInNumberedTabs = false;delegate.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["Research pair","A"])
        session.selectTab(number:1);#expect(session.activeTab === c)
        session.selectTab(number:2);#expect(session.activeTab === a)
    }

    @Test("Selecting a provider website in the native launcher navigates directly on Return")
    func navigationReturn() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:650),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;defer { window.close() }
        let bar = CommandBar();bar.install(in:try #require(window.contentView))
        let url = URL(string:"https://portal.example/")!
        let literal = try #require(CommandSearch.row(query:"portal",engine:.google))
        let rows = CommandSearch.addingResults([.navigation(url,title:"Portal home")],query:"portal",engine:.google,to:[literal])
        var action:CommandAction?
        bar.onRun = { action = $0;_ = $1;_ = $2 }
        bar.openNewTab(recentResults:[]);bar.setResults(rows);bar.select(1);bar.submit()
        #expect(action == .openURL(url) && !bar.isOpen)
    }

    @Test("The Shortcuts preference can exclude Favorites and restores its stored choice")
    func orderingPreference() throws {
        let settings = Settings.shared,old = Settings.shared.includesFavoritesInNumberedTabs
        defer { settings.includesFavoritesInNumberedTabs = old }
        let pane = ShortcutsSettingsViewController()
        let control = try #require(UITestSupport.descendants(of:pane.view).compactMap { $0 as? NSButton }.first { $0.title == "Include Favorites in numbered sidebar shortcuts" })
        #expect((control.state == .on) == old)
        control.state = old ? .off:.on
        #expect(control.sendAction(control.action,to:control.target))
        #expect(settings.includesFavoritesInNumberedTabs == !old)
        let reopened = ShortcutsSettingsViewController()
        let restored = try #require(UITestSupport.descendants(of:reopened.view).compactMap { $0 as? NSButton }.first { $0.title == control.title })
        #expect(restored.state == control.state)
    }

    @Test("Unopened Favorites are numbered but do not become phantom open tabs during cycling")
    func unopenedFavorite() {
        let (session,_) = fixture(),space = session.activeSpace
        space.addPinnedSite(.init(url:URL(string:"https://unopened.example/")!,title:"Unopened"))
        let a = page("A",in:session),b = page("B",in:session)
        session.selectTab(a);session.selectTab(offsetBy:1);#expect(session.activeTab === b)
        session.selectTab(offsetBy:1);#expect(session.activeTab === a)
        #expect(space.profile.favoriteTabs.isEmpty)
    }
}
