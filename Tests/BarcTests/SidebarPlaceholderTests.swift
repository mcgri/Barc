// Modified for Barc: source-observed empty address layout and profile-wide Favorites hint behavior, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Arc empty sidebar presentation", .serialized)
@MainActor
struct SidebarPlaceholderTests {
    @Test("The empty address matches Arc's inactive placeholder; real addresses retain their click action")
    func emptyAddress() throws {
        let address = AddressField()
        let host = UITestSupport.host(address,width:212,height:36)
        address.show(display:"",url:nil); host.layoutSubtreeIfNeeded()
        let button = try #require(UITestSupport.buttons(in:address).first { $0.accessibilityLabel()=="Address" })
        #expect(button.title=="Search or Enter URL…")
        #expect(button.font?.pointSize==13 && button.contentTintColor==Style.Colors.secondaryText)
        #expect(abs(button.frame.minX-34)<0.1)
        let leading = try #require(UITestSupport.descendants(of:address).compactMap { $0 as? NSImageView }.first)
        #expect(!leading.isHidden && leading.accessibilityLabel()=="Search")
        var opened=0; address.onOpen={opened += 1}; button.performClick(nil)
        #expect(opened==0 && !button.isEnabled)
        address.show(display:"example.invalid",url:URL(string:"https://example.invalid/path")!)
        host.layoutSubtreeIfNeeded()
        #expect(button.title=="example.invalid" && button.font?.pointSize==13)
        let ink = try #require(button.contentTintColor?.usingColorSpace(.deviceRGB))
        let expectedInk = try #require(Style.Colors.addressText.usingColorSpace(.deviceRGB))
        #expect(ink==expectedInk && abs(button.frame.minX-13)<0.1)
        #expect(leading.isHidden)
        button.performClick(nil)
        #expect(opened==1 && button.isEnabled)
        address.show(display:"plain.invalid",url:URL(string:"http://plain.invalid/")!)
        host.layoutSubtreeIfNeeded()
        #expect(!leading.isHidden && leading.contentTintColor==NSColor.systemOrange)
    }

    @Test("Dismissing the Favorites hint follows a shared profile while another profile retains its hint")
    func sharedHintDismissal() throws {
        let session=TestSession.make().0
        let profile=try #require(session.addProfile(named:"Shared"))
        _=session.addSpace(named:"First",profile:profile)
        let sidebar=SidebarViewController(session:session)
        let strip=try #require(UITestSupport.descendants(of:sidebar.view).compactMap { $0 as? PinnedTilesView }.first)
        let dismiss=try #require(UITestSupport.buttons(in:strip).first { $0.accessibilityLabel()=="Dismiss Favorites Hint" })
        dismiss.performClick(nil)
        #expect(strip.isHidden)
        let sibling=session.addSpace(named:"Second",profile:profile)
        #expect(strip.isHidden)
        _=session.addSpace(named:"Separate")
        #expect(!strip.isHidden)
        session.selectSpace(sibling)
        #expect(strip.isHidden)
    }
}
