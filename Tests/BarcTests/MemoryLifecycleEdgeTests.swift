// Modified for Barc: auxiliary surfaces, frame and capture protections, 2026-10-26.
import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

@Suite("Hibernation safety edges", .serialized)
@MainActor
struct HibernationSafetyEdgeTests {
    private func settings() -> Settings { Settings(defaults:UserDefaults(suiteName:"barc.memory-edge.\(UUID())")!) }

    @Test("An unedited select is safe; a selected file is protected without input events")
    func formEdges() async throws {
        let view = try await MemoryTestPage.make(html:"<select><option>One</option><option>Two</option></select><input type='file' id='file'>")
        #expect(await MemoryTestPage.safe(view))
        _ = try await view.evaluateJavaScript("const transfer=new DataTransfer(); transfer.items.add(new File(['fixture'],'draft.txt')); file.files=transfer.files; true")
        #expect(!(await MemoryTestPage.safe(view)))
    }

    @Test("An edited frame on another origin protects the entire tab")
    func crossOriginFrame() async throws {
        let server = try MemoryHTTPFixture(); defer { server.stop() }
        let base = try await server.start()
        let view = try await MemoryTestPage.make(html:"<iframe src='\(base.appending(path:"dirty").absoluteString)'></iframe>")
        #expect(!(await MemoryTestPage.safe(view)))
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('iframe').length") as? Int == 1)
    }

    private final class CapturingView: WKWebView {
        var microphone: WKMediaCaptureState = .none
        var camera: WKMediaCaptureState = .none
        override var microphoneCaptureState: WKMediaCaptureState { microphone }
        override var cameraCaptureState: WKMediaCaptureState { camera }
    }
    @Test("Muted native microphone and camera capture still prevent hibernation")
    func mutedNativeCapture() {
        let view = CapturingView(frame:.zero,configuration:WKWebViewConfiguration())
        #expect(PageHibernationGuard.nativeActivityAllowsSleep(view))
        for capture in [WKMediaCaptureState.active,.muted] {
            view.microphone = capture
            #expect(!PageHibernationGuard.nativeActivityAllowsSleep(view))
            view.microphone = .none;view.camera = capture
            #expect(!PageHibernationGuard.nativeActivityAllowsSleep(view))
            view.camera = .none
        }
    }

    @Test("Screen-capture tracks stay protected while live, including muted tracks")
    func captureTracks() async throws {
        let config = WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        let capture = """
            window.track=new EventTarget(); track.readyState='live'; track.enabled=false;
            Object.defineProperty(navigator,'mediaDevices',{value:{getDisplayMedia(){return Promise.resolve({getTracks(){return [track];}});}}});
            """
        config.userContentController.addUserScript(WKUserScript(source:capture,injectionTime:.atDocumentStart,forMainFrameOnly:true))
        PageHibernationGuard.shared.attach(config.userContentController)
        let view = WKWebView(frame:.zero,configuration:config)
        try await MemoryTestPage.load(view,html:"<p>Capture fixture</p>")
        _ = try await view.callAsyncJavaScript("await navigator.mediaDevices.getDisplayMedia(); return true;",arguments:[:],in:nil,contentWorld:.page)
        #expect(!(await MemoryTestPage.safe(view)))
        _ = try await view.evaluateJavaScript("track.readyState='ended'; track.dispatchEvent(new Event('ended')); true")
        #expect(await MemoryTestPage.safe(view))
    }

    @Test("A shared Favorite is inspected once and its profile stays active across Space switches")
    func sharedFavorite() async throws {
        let session = TestSession.make().0
        let profile = try #require(session.addProfile(named:"Shared fixture"))
        let first = session.addSpace(named:"One",profile:profile)
        let view = try await MemoryTestPage.make(identity:profile.identity)
        let favorite = session.adoptGlancedTab(view,after:session.activeTab)
        session.pin(favorite)
        let pin = try #require(profile.pinnedSites.first)
        var time:TimeInterval = 0, inspected = 0
        let preferences = settings();preferences.tabSuspensionMinutes = 0
        let driver = TabSuspender(session:session,settings:preferences,uptime:{time},inspectPage:{ page in
            inspected += 1
            return await PageHibernationGuard.shared.permitsHibernation(of: page)
        },additionalVisibleProfiles:{[]})
        let second = session.addSpace(named:"Two",profile:profile)
        time = 600;await driver.evaluate(.idle)
        #expect(favorite.isLoaded && inspected == 0)
        session.openPinnedSite(pin)
        #expect(session.activeSpace === second)
        session.selectSpace(first);time = 660;await driver.evaluate(.idle)
        #expect(favorite.isLoaded && inspected == 0)
        session.addSpace(named:"Elsewhere");time = 721;await driver.evaluate(.idle)
        #expect(!favorite.isLoaded && inspected == 1)
    }

    @Test("A protected pane keeps its hidden split together under critical pressure")
    func protectedSplit() async throws {
        let session = TestSession.make().0
        let firstView = try await MemoryTestPage.make(identity:session.activeSpace.identity)
        let first = session.adoptGlancedTab(firstView,after:session.activeTab)
        let draftView = try await MemoryTestPage.make(identity:session.activeSpace.identity,html:"<textarea id='draft'></textarea>")
        let draft = session.adoptGlancedTab(draftView,after:first)
        _ = try await draftView.evaluateJavaScript("draft.value='Protected'; draft.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(session.splitTabs([first,draft]))
        var time:TimeInterval = 0
        let driver = TabSuspender(session:session,settings:settings(),uptime:{time},additionalVisibleProfiles:{[]})
        session.addSpace(named:"Elsewhere");time = 61
        await driver.evaluate(.memoryCritical)
        #expect(first.isLoaded && draft.isLoaded)
        first.unload();draft.unload()
    }
}

@Suite("Hidden panel and preview budgets", .serialized)
@MainActor
struct HiddenPanelHibernationTests {
    @Test("Closing a panel starts a fresh minute; safe hidden views release and wake lazily")
    func hiddenPanel() async throws {
        let store = WebPanelStore(defaults:UserDefaults(suiteName:"barc.hidden-panel.\(UUID())")!)
        var time:TimeInterval = 0
        let controller = WebPanelViewController(store:store,uptime:{time})
        _ = controller.view
        #expect(controller.cachedWebViewCount == 0,"A closed panel should not load its default pages")
        let panel = WebPanel(title:"Fixture",url:URL(string:"http://127.0.0.1/fixture/")!)
        store.add(panel:panel)
        let view = try await MemoryTestPage.make(identity:.standard)
        controller.adoptWebView(view,for:panel)
        #expect(controller.cachedWebViewCount == 1)
        time = 300;store.isOpen = false
        await controller.hibernateHiddenPanels(after:60,now:359)
        #expect(controller.cachedWebView(for:panel.id) === view)
        await controller.hibernateHiddenPanels(after:60,now:360)
        #expect(controller.cachedWebViewCount == 0)
        store.select(id:panel.id)
        #expect(controller.cachedWebViewCount == 1)
        store.isOpen = false
        controller.cachedWebView(for:panel.id)?.stopLoading()
    }

    @Test("Panel drafts and the scratchpad are retained, and removed entries are pruned")
    func panelDraft() async throws {
        let store = WebPanelStore(defaults:UserDefaults(suiteName:"barc.panel-draft.\(UUID())")!)
        let controller = WebPanelViewController(store:store,uptime:{0})
        _ = controller.view
        let panel = WebPanel(title:"Draft fixture",url:URL(string:"http://127.0.0.1/fixture/")!)
        store.add(panel:panel)
        let view = try await MemoryTestPage.make(identity:.standard,html:"<textarea id='draft'>Draft</textarea>")
        controller.adoptWebView(view,for:panel)
        _ = try await view.evaluateJavaScript("draft.value='Keep this note'; draft.dispatchEvent(new Event('input', {bubbles:true})); true")
        store.isOpen = false
        await controller.hibernateHiddenPanels(after:60,now:3600)
        #expect(controller.cachedWebView(for:panel.id) === view)
        #expect(try await view.evaluateJavaScript("draft.value") as? String == "Keep this note")
        store.remove(id:panel.id)
        #expect(controller.cachedWebView(for:panel.id) == nil)
        let scratch = try #require(store.panels.first { $0.isScratchpad })
        let scratchView = try await MemoryTestPage.make(identity:.standard)
        controller.adoptWebView(scratchView,for:scratch)
        store.isOpen = false
        await controller.hibernateHiddenPanels(after:60,now:3600)
        #expect(controller.cachedWebView(for:scratch.id) === scratchView)
    }

    @Test("Thumbnail limits account for bytes and trimming resets the budget")
    func previewByteLimit() throws {
        let store = TabSnapshotStore(capacity:30,byteLimit:5000)
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:128,bitsPerPixel:32))
        let image = NSImage(size:NSSize(width:32,height:32));image.addRepresentation(pixels)
        let first = UUID(),second = UUID()
        store.setSnapshot(image,for:first);store.setSnapshot(image,for:second)
        #expect(store.count == 1 && store.snapshot(for:first) == nil)
        #expect(store.totalCost == 4096)
        store.clear()
        #expect(store.count == 0 && store.totalCost == 0)
    }
}

extension HibernationSafetyEdgeTests {
    @Test("Background call audio stays enabled and ordinary media suspension returns after the call closes")
    func callMediaSuspension() async throws {
        let session = TestSession.make().0
        let view = try await MemoryTestPage.make(identity:session.activeSpace.identity)
        let tab = session.adoptGlancedTab(view,after:session.activeTab)
        _ = try await view.evaluateJavaScript("window.callPeer=new RTCPeerConnection(); callPeer.createDataChannel('call-fixture'); true")
        for _ in 0..<50 where !PageHibernationGuard.shared.hasRealtimeActivity(in:view) {try await Task.sleep(for:.milliseconds(10))}
        session.addSpace(named:"Elsewhere");session.updateMediaSuspension()
        #expect(!tab.isMediaSuspended,"A call keeps its audio when its profile leaves view")
        _ = try await view.evaluateJavaScript("callPeer.close(); true")
        for _ in 0..<50 where !tab.isMediaSuspended {try await Task.sleep(for:.milliseconds(10))}
        #expect(tab.isMediaSuspended,"Ordinary hidden media is paused after the call ends")
        tab.setPictureInPicture(true)
        #expect(!tab.isMediaSuspended)
        tab.setPictureInPicture(false)
        #expect(tab.isMediaSuspended)
        tab.unload()
    }
}
