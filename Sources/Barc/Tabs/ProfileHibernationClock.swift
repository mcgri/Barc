// Modified for Barc: inactivity starts when content leaves view, 2026-10-26.
import Foundation

/// Monotonic, process-local clocks. Restored wall-clock dates are for the
/// archive, never permission to unload a page just after it becomes hidden.
struct ProfileHibernationClock {
    private(set) var visibleTabs: Set<UUID> = []
    private(set) var visibleProfiles: Set<Space.Identity> = []
    private var tabHiddenAt: [UUID: TimeInterval] = [:]
    private var profileHiddenAt: [Space.Identity: TimeInterval] = [:]

    mutating func update(tabs: [UUID: Space.Identity], visible: Set<UUID>,
                         additionalProfiles: Set<Space.Identity> = [], now: TimeInterval) {
        let profiles = Set(tabs.values)
        let active = Set(visible.compactMap { tabs[$0] }).union(additionalProfiles)
        tabHiddenAt = tabHiddenAt.filter { tabs[$0.key] != nil }
        profileHiddenAt = profileHiddenAt.filter { profiles.contains($0.key) }
        for id in tabs.keys {
            if visible.contains(id) { tabHiddenAt[id] = nil }
            else if visibleTabs.contains(id) || tabHiddenAt[id] == nil { tabHiddenAt[id] = now }
        }
        for profile in profiles {
            if active.contains(profile) { profileHiddenAt[profile] = nil }
            else if visibleProfiles.contains(profile) || profileHiddenAt[profile] == nil { profileHiddenAt[profile] = now }
        }
        visibleTabs = visible
        visibleProfiles = active
    }

    func tabIdle(_ id: UUID, now: TimeInterval) -> TimeInterval {
        tabHiddenAt[id].map { max(0, now - $0) } ?? 0
    }
    func profileIdle(_ identity: Space.Identity, now: TimeInterval) -> TimeInterval {
        profileHiddenAt[identity].map { max(0, now - $0) } ?? 0
    }
}
