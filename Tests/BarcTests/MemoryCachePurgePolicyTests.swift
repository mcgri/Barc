import Testing
@testable import Barc

@MainActor
struct MemoryCachePurgePolicyTests {
    @Test func pressurePurgeInterval() {
        #expect(TabSuspension.shouldPurgeMemoryCache(now: 0, lastPurge: nil))
        #expect(!TabSuspension.shouldPurgeMemoryCache(now: 59.99, lastPurge: 0))
        #expect(TabSuspension.shouldPurgeMemoryCache(now: 60, lastPurge: 0))
        #expect(!TabSuspension.shouldPurgeMemoryCache(now: 10, lastPurge: 20))
    }
}
