import AppKit
import Testing
@testable import Barc

/// A Favorite resumes its tab wherever that tab last was, so a page that left
/// the site had no way back: Gmail sent to Google's marketing page by a
/// signed-out session stayed there until the Favorite was unpinned.
@Suite("Resetting a Favorite", .serialized)
@MainActor
struct FavoriteResetTests {
    private let gmail = URL(string: "https://mail.google.com/mail/u/0/#inbox")!
    private let marketing = URL(string: "https://workspace.google.com/intl/en-US/gmail/#search/jet2/message")!
    private let signIn = URL(string: "https://accounts.google.com/v3/signin/identifier?continue=mail")!

    private func favorite(at home: URL? = nil) throws -> (session: BrowserSession, tab: Tab, site: PinnedSite) {
        let session = TestSession.make().0
        let tab = session.newTab(url: home ?? gmail)
        session.pin(tab)
        let site = try #require(session.activeSpace.pinnedSites.first { $0.id == tab.pinnedSiteID })
        return (session, tab, site)
    }

    @Test("A Favorite goes back to its own address, never to a stale saved page")
    func ownAddress() throws {
        let (session, tab, site) = try favorite()
        // How the imported tab came to hold a sign-in page as its saved page.
        tab.load(signIn)
        tab.setKeepsInSidebar(true)
        tab.load(marketing)
        #expect(tab.pinnedPageURL == signIn)
        #expect(session.canResetFavorite(tab))
        #expect(session.resetFavorite(tab))
        #expect(tab.url == gmail)
        #expect(tab.pinnedSiteID == site.id, "Resetting must leave it a Favorite")
        #expect(session.activeSpace.pinnedSites.first?.url == gmail)
    }

    @Test("Switching to a Favorite keeps its page; clicking it again brings it home")
    func secondClick() throws {
        let (session, tab, site) = try favorite()
        tab.load(marketing)
        let other = session.newTab(url: URL(string: "https://example.com/")!)
        #expect(session.activeTab === other)
        session.openPinnedSite(site)
        #expect(session.activeTab === tab && tab.url == marketing, "Switching back must not discard the page")
        session.openPinnedSite(site)
        #expect(session.activeTab === tab && tab.url == gmail)
    }

    @Test("Clicking the Favorite you are on leaves a page that is still on its site",
          arguments: [("https://github.com/", "https://github.com/mcgri/Barc"),
                      ("https://example.com/", "https://www.example.com/page"),
                      ("https://www.example.com/", "https://example.com/page"),
                      ("https://mail.google.com/mail/u/0/#inbox", "https://mail.google.com/mail/u/0/#inbox/message")])
    func stayingOnSite(home: String, page: String) throws {
        let (session, tab, site) = try favorite(at: URL(string: home)!)
        tab.load(URL(string: page)!)
        session.openPinnedSite(site)
        #expect(tab.url == URL(string: page)!)
    }

    @Test("Reset is offered anywhere off the Favorite's page, but not on it")
    func offered() throws {
        let (session, tab, _) = try favorite(at: URL(string: "https://github.com/")!)
        #expect(!session.canResetFavorite(tab))
        tab.load(URL(string: "https://github.com/#readme")!)
        #expect(!session.canResetFavorite(tab), "A fragment is the same page")
        tab.load(URL(string: "https://github.com/mcgri/Barc")!)
        #expect(session.canResetFavorite(tab))
    }

    @Test("Space pins and ordinary tabs are untouched")
    func otherTabs() {
        let session = TestSession.make().0
        let plain = session.newTab(url: gmail)
        plain.load(marketing)
        #expect(!session.canResetFavorite(plain) && !session.resetFavorite(plain))
        let pin = session.newTab(url: gmail)
        session.setSidebarPin(true, for: pin)
        pin.load(marketing)
        #expect(!session.canResetFavorite(pin))
        #expect(session.canResetSidebarPin(pin))
    }

    @Test("A split Favorite has no single address to go back to")
    func split() {
        let session = TestSession.make().0
        let pages = (0..<2).map { session.newTab(url: URL(string: "https://split-favorite.invalid/\($0)")!) }
        session.splitTabs(pages)
        session.pin(pages[0])
        #expect(pages[0].pinnedSiteID != nil)
        pages[0].load(marketing)
        #expect(!session.canResetFavorite(pages[0]))
        #expect(!session.resetFavorite(pages[0]))
        #expect(pages[0].url == marketing)
    }

    @Test("Reset Tab reaches a Favorite; replacing the pin's page still does not")
    func palette() throws {
        _ = NSApplication.shared
        let (session, tab, _) = try favorite()
        let controller = BrowserWindowController(session: session)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        func ids() -> Set<String> { Set(CommandCatalog.available(in: session).map(\.id)) }
        #expect(!ids().contains("reset-tab"))
        tab.load(marketing)
        #expect(ids().contains("reset-tab"))
        #expect(!ids().contains("replace-pin-with-current-page"), "That writes a field a Favorite does not use")
        #expect(controller.runPaletteCommand("reset-tab"))
        #expect(tab.url == gmail)
    }

    @Test("A Favorite's right-click menu offers Reset Tab only when it has somewhere to go back to")
    func tileMenu() throws {
        _ = NSApplication.shared
        let (session, tab, site) = try favorite()
        let sidebar = SidebarViewController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let host = UITestSupport.host(sidebar.view, width: 228, height: 760)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.alphaValue = 0
        window.orderFront(nil)
        let tile = try #require(UITestSupport.descendants(of: host).first { $0.accessibilityLabel() == site.title })
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(try #require(tile.menu(for: event)).items.allSatisfy { $0.title != "Reset Tab" })
        tab.load(marketing)
        let menu = try #require(tile.menu(for: event))
        let reset = try #require(menu.items.first { $0.title == "Reset Tab" })
        #expect(menu.items.contains { $0.title == "Unpin" })
        #expect(NSApp.sendAction(try #require(reset.action), to: reset.target, from: reset))
        #expect(tab.url == gmail)
    }
}
