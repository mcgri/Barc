// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import Foundation

/// Decides which tabs should give their memory back.
///
/// Pure logic, separated from the timer and the memory-pressure source that
/// drive it, so every rule below is a unit test rather than a guess about what
/// the browser will do after ten minutes.
@MainActor
enum TabSuspension {
    enum Trigger: Equatable {
        /// A tab has simply been in the background too long.
        case idle
        /// The system is short on memory.
        case memoryWarning
        /// The system is critically short on memory.
        case memoryCritical
    }

    /// Everything the policy decides from, for one tab.
    ///
    /// The policy is stated over plain facts so the rules can be tested without
    /// a window, a web view and a ten-minute wait.
    struct TabState: Equatable, Sendable {
        let id: Tab.ID
        let isLoaded: Bool
        let lastActiveAt: Date
        /// The user's "Keep Awake" lock. Honoured for idle sweeps and for
        /// every memory-pressure trigger as well as idle sweeps.
        let keepsAwake: Bool
        /// Measured physical footprint of the content process, or nil when unavailable.
        var footprint: UInt64? = nil
        /// Content process identifier used to count shared memory once.
        var processID: Int32? = nil
        /// Whether other live pages use this content process.
        var sharedProcess = false

        init(id: Tab.ID, isLoaded: Bool, lastActiveAt: Date, keepsAwake: Bool = false) {
            self.id = id
            self.isLoaded = isLoaded
            self.lastActiveAt = lastActiveAt
            self.keepsAwake = keepsAwake
        }

        @MainActor
        init(_ tab: Tab) {
            self.init(
                id: tab.id,
                isLoaded: tab.isLoaded,
                lastActiveAt: tab.lastActiveAt,
                keepsAwake: tab.keepsAwake
            )
        }
    }

    /// How idle a tab must be before each trigger will unload it.
    ///
    /// A warning may shorten the age threshold, but never removes protection
    /// for visible content or work the user asked to keep awake.
    static let warningThreshold: TimeInterval = 60
    static let heavyThreshold: UInt64 = 500 * 1024 * 1024
    static let heavyDelay: TimeInterval = 180
    static let budgetGrace: TimeInterval = 120

    /// Both pressure levels share one memory-cache purge interval.
    static func shouldPurgeMemoryCache(now: TimeInterval, lastPurge: TimeInterval?) -> Bool {
        guard let lastPurge else { return true }
        return now - lastPurge >= 60
    }

    /// Count each attributed process once. Unknown attribution adds no charge.
    static func budgetOrder(among tabs: [TabState], protecting protected: Set<Tab.ID>,
                            budget: UInt64?, cohorts: [Set<Tab.ID>] = [], now: Date) -> [Tab.ID] {
        guard let budget else { return [] }
        let background = tabs.filter { $0.isLoaded && !$0.keepsAwake && !protected.contains($0.id) }
        var processes: [Int32: UInt64] = [:]
        for tab in background {
            if let pid = tab.processID, let bytes = tab.footprint {
                processes[pid] = max(processes[pid] ?? 0, bytes)
            }
        }
        guard processes.values.reduce(0, +) > budget else { return [] }
        var eligible = Set(background.filter { now.timeIntervalSince($0.lastActiveAt) >= budgetGrace }.map(\.id))
        let loaded = Set(tabs.filter(\.isLoaded).map(\.id))
        for _ in cohorts {
            for cohort in cohorts where !cohort.intersection(loaded).isSubset(of: eligible) {
                eligible.subtract(cohort)
            }
        }
        return background.filter { eligible.contains($0.id) }.sorted {
            let leftRank = $0.processID == nil || $0.footprint == nil ? 2 : ($0.sharedProcess ? 1 : 0)
            let rightRank = $1.processID == nil || $1.footprint == nil ? 2 : ($1.sharedProcess ? 1 : 0)
            if leftRank != rightRank { return leftRank < rightRank }
            let left = $0.processID == nil ? 0 : ($0.footprint ?? 0)
            let right = $1.processID == nil ? 0 : ($1.footprint ?? 0)
            if left != right { return left > right }
            if $0.lastActiveAt != $1.lastActiveAt { return $0.lastActiveAt < $1.lastActiveAt }
            return $0.id.uuidString < $1.id.uuidString
        }.map(\.id)
    }

    /// - Parameters:
    ///   - protectedIDs: the tabs **currently rendered**, not the selected one.
    ///     They are the same set only while one page is on screen at a time;
    ///     a split puts two to four pages there and the unfocused panes are as
    ///     visible as the focused one. Suspending them would blank a pane the
    ///     user is looking at.
    ///   - cohorts: sets of tabs that must be loaded or unloaded together --
    ///     the members of each split. Unloading is all-or-nothing inside a
    ///     cohort. Every loaded member must qualify independently; a visible,
    ///     protected or recently used member keeps the whole group loaded.
    static func candidates(
        among tabs: [Tab],
        protecting protectedIDs: Set<Tab.ID>,
        idleThreshold: TimeInterval?,
        trigger: Trigger,
        cohorts: [Set<Tab.ID>] = [],
        now: Date = .now
    ) -> [Tab] {
        let chosen = candidateIDs(
            among: tabs.map(TabState.init),
            protecting: protectedIDs,
            idleThreshold: idleThreshold,
            trigger: trigger,
            cohorts: cohorts,
            now: now
        )
        return tabs.filter { chosen.contains($0.id) }
    }

    /// The rule itself, over values.
    static func candidateIDs(
        among tabs: [TabState],
        protecting protectedIDs: Set<Tab.ID>,
        idleThreshold: TimeInterval?,
        trigger: Trigger,
        cohorts: [Set<Tab.ID>] = [],
        now: Date = .now
    ) -> Set<Tab.ID> {
        let minimumIdle: TimeInterval?
        switch trigger {
        case .idle:
            // Nothing to do when the user has turned suspension off.
            guard let idleThreshold else { return [] }
            minimumIdle = idleThreshold
        case .memoryWarning:
            minimumIdle = warningThreshold
        case .memoryCritical:
            // Drop the age requirement, while retaining activity protection.
            minimumIdle = nil
        }

        // Protection never yields to memory pressure. A draft or a call is
        // more valuable than an automatic attempt to reclaim its page.
        var protected = protectedIDs
        protected.formUnion(tabs.lazy.filter(\.keepsAwake).map(\.id))
        let loaded = Set(tabs.lazy.filter(\.isLoaded).map(\.id))
        var chosen = Set(tabs.lazy.filter { tab in
            guard tab.isLoaded, !protected.contains(tab.id) else { return false }
            guard let minimumIdle else { return true }
            let heavy = trigger == .idle && !tab.sharedProcess && tab.processID != nil
                && (tab.footprint ?? 0) >= heavyThreshold
            let threshold = heavy ? min(minimumIdle, heavyDelay) : minimumIdle
            return now.timeIntervalSince(tab.lastActiveAt) >= threshold
        }.map(\.id))
        // Never unload a recently used or protected sibling to match an older
        // pane. A complete group must independently qualify as a whole.
        for cohort in cohorts {
            let members = cohort.intersection(loaded)
            if !members.isSubset(of: chosen) { chosen.subtract(cohort) }
        }

        return chosen
    }
}
