import Foundation
import Testing
@testable import Barc

@MainActor
struct BackgroundMemoryPolicyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)
    private func tab(_ bytes: UInt64? = nil, pid: Int32? = nil, age: Double = 300,
                     shared: Bool = false, awake: Bool = false) -> TabSuspension.TabState {
        var state = TabSuspension.TabState(id: UUID(), isLoaded: true,
            lastActiveAt: now.addingTimeInterval(-age), keepsAwake: awake)
        state.footprint = bytes
        state.processID = pid
        state.sharedProcess = shared
        return state
    }
    private func order(_ tabs: [TabSuspension.TabState], budget: UInt64? = 1,
                       protected: Set<UUID> = [], cohorts: [Set<UUID>] = []) -> [UUID] {
        TabSuspension.budgetOrder(among: tabs, protecting: protected, budget: budget, cohorts: cohorts, now: now)
    }

    @Test func heaviestFirstWithLRUTiesAndUnknownLast() {
        let small = tab(100, pid: 1), heavy = tab(900, pid: 2)
        let older = tab(900, pid: 3, age: 600), unknown = tab(age: 900)
        #expect(order([small, unknown, heavy, older]) == [older.id, heavy.id, small.id, unknown.id])
    }
    @Test func sharedProcessesFollowKnownUnsharedAndPrecedeUnknown() {
        let unshared = tab(100, pid: 1)
        let shared = tab(900, pid: 2, shared: true)
        let unknown = tab(age: 900)
        #expect(order([unknown, shared, unshared]) == [unshared.id, shared.id, unknown.id])
    }
    @Test func sharedProcessCountedOnce() {
        let a = tab(900, pid: 1, shared: true), b = tab(900, pid: 1, shared: true)
        #expect(order([a, b], budget: 1000).isEmpty)
        #expect(order([a, b], budget: 800).count == 2)
    }
    @Test func unknownAttributionAddsNoCharge() {
        #expect(order([tab(900), tab()]).isEmpty)
    }
    @Test func gracePeriodAndBoundary() {
        let recent = tab(900, pid: 1, age: 119.99), ready = tab(900, pid: 2, age: 120)
        #expect(order([recent, ready]) == [ready.id])
    }
    @Test func protectionsWin() {
        let locked = tab(900, pid: 1, awake: true), visible = tab(900, pid: 2)
        #expect(order([locked, visible], protected: [visible.id]).isEmpty)
    }
    @Test func cohortsRequireEveryLoadedMember() {
        let a = tab(900, pid: 1), b = tab(100, pid: 2, age: 10)
        #expect(order([a, b], cohorts: [[a.id, b.id]]).isEmpty)
        let c = tab(100, pid: 3)
        #expect(Set(order([a, c], cohorts: [[a.id, c.id]])) == [a.id, c.id])
        #expect(order([a, c], protected: [c.id], cohorts: [[a.id, c.id]]).isEmpty)
    }
    @Test func budgetOffAndAlreadyUnderLimit() {
        let a = tab(900, pid: 1)
        #expect(order([a], budget: nil).isEmpty)
        #expect(order([a], budget: 900).isEmpty)
    }
    @Test func heavyRuleRequiresUnsharedMeasuredProcessAndThreeMinutes() {
        let bytes = TabSuspension.heavyThreshold
        let early = tab(bytes, pid: 1, age: 179.99), ready = tab(bytes, pid: 2, age: 180)
        let shared = tab(bytes, pid: 3, shared: true), unknown = tab(bytes)
        let small = tab(bytes - 1, pid: 4)
        let chosen = TabSuspension.candidateIDs(among: [early, ready, shared, unknown, small],
            protecting: [], idleThreshold: 600, trigger: .idle, now: now)
        #expect(chosen == [ready.id])
        #expect(TabSuspension.candidateIDs(among: [ready], protecting: [ready.id],
            idleThreshold: 600, trigger: .idle, now: now).isEmpty)
        #expect(TabSuspension.candidateIDs(among: [ready], protecting: [],
            idleThreshold: nil, trigger: .idle, now: now).isEmpty)
        #expect(TabSuspension.candidateIDs(among: [tab(bytes, pid: 5, age: 60)], protecting: [],
            idleThreshold: 60, trigger: .idle, now: now).count == 1)
    }
    @Test func budgetStopsAfterEnoughMemoryWasReleased() {
        var heavy = tab(900, pid: 1)
        let small = tab(100, pid: 2)
        #expect(order([heavy, small], budget: 500).first == heavy.id)
        heavy = TabSuspension.TabState(id: heavy.id, isLoaded: false, lastActiveAt: heavy.lastActiveAt)
        #expect(order([heavy, small], budget: 500).isEmpty)
    }
    @Test func settingsDefaultChoicesAndOff() {
        let name = "barc.tests.memory-budget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        #expect(settings.backgroundMemoryGB == 2)
        #expect(settings.backgroundMemoryBudget == 2 * 1024 * 1024 * 1024)
        #expect(Settings.backgroundMemoryChoices == [0, 1, 2, 4])
        settings.backgroundMemoryGB = 0
        #expect(settings.backgroundMemoryBudget == nil)
        settings.backgroundMemoryGB = 4
        #expect(settings.backgroundMemoryBudget == 4 * 1024 * 1024 * 1024)
    }

}
