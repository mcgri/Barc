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
    /// The policy reads four facts and no more, so it is stated over those four
    /// facts. That is what lets the rules be tested with plain values instead of
    /// a window, a web view and a ten-minute wait.
    struct TabState: Equatable, Sendable {
        let id: Tab.ID
        let isLoaded: Bool
        let lastActiveAt: Date
        /// The user's "Keep Awake" lock. Honoured for idle sweeps and for
        /// every memory-pressure trigger as well as idle sweeps.
        let keepsAwake: Bool

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
            return now.timeIntervalSince(tab.lastActiveAt) >= minimumIdle
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
