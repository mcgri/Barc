import AppKit
import Testing
import WebKit
@testable import Barc

/// WebKit offers "Open Link in New Window", and Barc has one main window, so
/// the item opened a tab under a name that said otherwise.
@Suite("Open in New Tab on a page's menu", .serialized)
@MainActor
struct PageNewTabMenuTests {
    private func settings() -> Settings { Settings(defaults: UserDefaults(suiteName: "test.newtab.\(UUID())")!) }

    private func customized(hiding hidden: [String] = []) throws -> [String] {
        let settings = settings()
        settings.contextMenuHiddenTitles = hidden
        let menu = NSMenu()
        for (title, id) in [("Open Link", "WKMenuItemIdentifierOpenLink"),
                            ("Open Link in New Window", "WKMenuItemIdentifierOpenLinkInNewWindow"),
                            ("Open Image in New Window", "WKMenuItemIdentifierOpenImageInNewWindow"),
                            ("Open Frame in New Window", "WKMenuItemIdentifierOpenFrameInNewWindow"),
                            ("Move Tab to New Window", "")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if !id.isEmpty { item.identifier = NSUserInterfaceItemIdentifier(id) }
            menu.addItem(item)
        }
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        ContextMenuManager(settings: settings).customize(menu: menu, for: WKWebView(frame: .zero), event: event, pendingLink: nil)
        return menu.items.map(\.title)
    }

    @Test("WebKit's new-window items say tab; an item that is not WebKit's keeps its name")
    func relabelled() throws {
        let titles = try customized()
        #expect(titles.contains("Open Link in New Tab"))
        #expect(titles.contains("Open Image in New Tab"))
        #expect(titles.contains("Open Frame in New Tab"))
        #expect(titles.contains("Open Link"))
        #expect(titles.contains("Move Tab to New Window"))
        #expect(!titles.contains("Open Link in New Window"))
    }

    @Test("The hidden-items list keeps working under the old name and takes the new one",
          arguments: ["Open Image in New Window", "Open Image in New Tab"])
    func hiddenItems(name: String) throws {
        let titles = try customized(hiding: [name.lowercased()])
        #expect(!titles.contains { $0.hasPrefix("Open Image") })
        #expect(titles.contains("Open Link in New Tab"))
    }

    /// Opt-in: `BARC_REAL_MENU_TEST=1 swift test --filter PageNewTabMenuTests`.
    /// Alongside the rest of the suite, a real context menu ended the whole run
    /// early with exit code 0, hiding every test after it.
    @Test("On a real page the item reads New Tab and opens one",
          .enabled(if: ProcessInfo.processInfo.environment["BARC_REAL_MENU_TEST"] != nil))
    func realMenu() async throws {
        _ = NSApplication.shared
        let fixture = try MemoryHTTPFixture()
        let address = try await fixture.start()
        defer { fixture.stop() }
        let session = TestSession.make().0
        let tab = session.newTab(url: URL(string: "about:blank")!)
        defer { tab.unload() }
        let view = tab.webView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        view.loadHTMLString("<!doctype html><a style='position:fixed;inset:0' href='\(address)child'>A link</a><i id='ready'></i>", baseURL: address)
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(10))
            if !view.isLoading, (try? await view.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
        }
        var titles: [String] = []
        GlanceWebView.testMenuWillOpen = { menu in
            titles = menu.items.map(\.title)
            if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
                menu.performActionForItem(at: index)
            }
            RunLoop.main.perform(inModes: [.eventTracking]) { menu.cancelTrackingWithoutAnimation() }
        }
        defer { GlanceWebView.testMenuWillOpen = nil }
        let before = session.allTabs.count
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .rightMouseDown { view.rightMouseDown(with: event) } else { view.rightMouseUp(with: event) }
        }
        for _ in 0..<300 where session.allTabs.count == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(titles.contains("Open Link in New Tab"))
        #expect(!titles.contains { $0.contains("New Window") })
        #expect(session.allTabs.count == before + 1)
    }
}
