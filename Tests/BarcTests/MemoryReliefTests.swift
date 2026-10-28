import Testing
@testable import Barc

struct MemoryReliefTests {
    @Test func debouncesRequests() {
        var schedule = MemoryReliefSchedule()
        let first = schedule.accept(at: 10)
        let repeated = schedule.accept(at: 11)
        let early = schedule.accept(at: 189)
        let due = schedule.accept(at: 190)
        #expect(first)
        #expect(!repeated)
        #expect(!early)
        #expect(due)
    }

    @Test func auxiliaryCacheBudget() {
        #expect(RAMCacheManager.memoryCapacity(for: .standard) == 4 * 1024 * 1024)
        #expect(RAMCacheManager.memoryCapacity(for: .ramOnly) == 4 * 1024 * 1024)
        #expect(RAMCacheManager.memoryCapacity(for: .disabled) == 0)
    }
}
