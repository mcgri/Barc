import Foundation
import Testing
@testable import Barc

@Suite("RustCore and out-of-line interaction state")
struct RustCoreAndStateStoreTests {
    @Test("InteractionStateStore compresses, roundtrips, and prunes state blobs")
    func roundtripsAndPrunes() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "barc-state-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InteractionStateStore(directory: dir)

        let payload = Data(repeating: 0x5A, count: 64 * 1024)
        let key = try #require(store.store(payload, forKey: "tab-1"))
        #expect(key == "tab-1")

        let loaded = try #require(store.load(forKey: "tab-1"))
        #expect(loaded == payload)

        // File on disk should be dramatically smaller than raw 64 KB.
        let file = dir.appending(path: "tab-1.barcstate")
        let diskSize = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? Int.max
        #expect(diskSize < 2048)

        // Pruning drops unreferenced keys.
        store.prune(keeping: [])
        #expect(store.load(forKey: "tab-1") == nil)
    }

    @Test("Oversized interactionState blobs are dropped to prevent session bloat")
    func dropsOversizedBlobs() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "barc-state-cap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InteractionStateStore(directory: dir)

        let huge = Data(repeating: 0x11, count: InteractionStateStore.maxUncompressedBytes + 1)
        #expect(store.store(huge, forKey: "huge-tab") == nil)
        #expect(store.load(forKey: "huge-tab") == nil)
    }

    @Test("BrowserSession.suspend honours allowVisible for background active-tab sleep")
    @MainActor
    func suspendAllowVisible() {
        let session = BrowserSession(database: nil, sessionStore: SessionStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "barc-suspend-\(UUID()).json")))
        let tab = session.newTab(url: URL(string: "https://example.com")!)
        _ = tab.webView()
        #expect(tab.isLoaded)

        // Default suspend protects the visible tab.
        #expect(session.suspend([tab]) == 0)
        #expect(tab.isLoaded)

        // Background active-tab sleep explicitly allows unloading the visible tab.
        #expect(session.suspend([tab], allowVisible: true) == 1)
        #expect(!tab.isLoaded)
    }
}
