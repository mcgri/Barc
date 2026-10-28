import AppKit
import Dispatch
import Combine
import WebKit

/// Drives `TabSuspension`: a periodic idle check and the system's own
/// memory-pressure signal.
///
/// `DispatchSource.makeMemoryPressureSource` is the same kernel signal macOS
/// uses to manage memory itself, so the browser reacts to real pressure rather
/// than to a threshold we invented.
@MainActor
final class TabSuspender {
    /// How often idle tabs are checked. Well below the shortest idle threshold
    /// the user can choose, and cheap: it walks a list and compares dates.
    private static let checkInterval: TimeInterval = 10

    private let session: BrowserSession
    private let settings: Settings
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var activationObservers: [NSObjectProtocol] = []

    private let uptime: () -> TimeInterval
    private let inspectPage: (WKWebView) async -> Bool
    private let validatePage: (WKWebView) -> Bool
    private let protectsTransfer: (WKWebView) -> Bool
    private let additionalVisibleProfiles: () -> Set<Space.Identity>
    private var clock = ProfileHibernationClock()
    private var subscription: AnyCancellable?
    private var sweepTask: Task<Void, Never>?
    private var sweepGeneration = UUID()
    private var pendingTrigger: TabSuspension.Trigger?
    private var visibilityRevision = 0
    private var sweepResources: [Tab.ID: TabResourceUsage] = [:]
    private var budgetPriority: [Tab.ID] = []
    private var lastMemoryCachePurge: TimeInterval?
    private(set) var lastSweepUnloadedCount = 0

    init(session: BrowserSession, settings: Settings = .shared,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         inspectPage: @escaping (WKWebView) async -> Bool = { await PageHibernationGuard.shared.permitsHibernation(of: $0) },
         validatePage: @escaping (WKWebView) -> Bool = { PageHibernationGuard.shared.hasCurrentApproval(for: $0) },
         protectsTransfer: @escaping (WKWebView) -> Bool = { DownloadManager.shared.protectsFromHibernation($0) },
         additionalVisibleProfiles: @escaping () -> Set<Space.Identity> = { WebEnvironment.shared.visibleIdentities }) {
        self.session = session
        self.settings = settings
        self.uptime = uptime
        self.inspectPage = inspectPage
        self.validatePage = validatePage
        self.protectsTransfer = protectsTransfer
        self.additionalVisibleProfiles = additionalVisibleProfiles
        subscription = session.changes.sink { [weak self] change in
            switch change {
            case .activeTab, .spaces, .tabs, .structure:
                self?.visibilityRevision += 1
                self?.sweepTask?.cancel()
                self?.updateClocks()
            case .tab, .bookmarks: break
            }
        }
        updateClocks()
    }

    private func updateClocks() {
        let tabs = session.allTabs
        // A detached session selection still protects its profile, and visible
        // auxiliary surfaces protect theirs even when another Space is selected.
        for tab in tabs where clock.visibleTabs.contains(tab.id) && !session.visibleTabIDs.contains(tab.id) { tab.markActive() }
        let extra = additionalVisibleProfiles().union([session.activeSpace.identity])
        clock.update(tabs: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.identity) }),
                     visible: session.visibleTabIDs, additionalProfiles: extra, now: uptime())
    }

    private func requestEvaluation(_ trigger: TabSuspension.Trigger) {
        if sweepTask != nil {
            if pendingTrigger == nil || trigger == .memoryCritical || (trigger == .memoryWarning && pendingTrigger == .idle) { pendingTrigger = trigger }
            return
        }
        let generation = UUID()
        sweepGeneration = generation
        sweepTask = Task { [weak self] in
            guard let self else { return }
            await self.evaluate(trigger)
            guard self.sweepGeneration == generation else { return }
            self.sweepTask = nil
            if !Task.isCancelled, let pending = self.pendingTrigger {
                self.pendingTrigger = nil
                self.requestEvaluation(pending)
            }
        }
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestEvaluation(.idle) }
        }
        // Measured: App Nap defers a tolerant timer in a background app almost
        // indefinitely, so a sweep can be an hour late. A small tolerance keeps
        // the timer useful while the app is in front; the notifications below
        // cover the case where it was not.
        timer.tolerance = 5
        self.timer = timer

        // Sweeping when the app is activated catches up on everything App Nap
        // deferred, which is exactly when reclaimed memory matters to the user.
        // Sweeping on deactivation releases background tabs on the way out.
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestEvaluation(.idle) }
            }
            activationObservers.append(observer)
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let event = self.pressureSource?.data else { return }
            MainActor.assumeIsolated {
                self.requestEvaluation(event.contains(.critical) ? .memoryCritical : .memoryWarning)
            }
        }
        source.resume()
        pressureSource = source
    }

    /// Callers own the lifetime: `AppDelegate` starts this at launch and the
    /// app process ends with it. A `deinit` cannot touch the timer, which is
    /// not `Sendable`.
    func stop() {
        sweepGeneration = UUID()
        sweepTask?.cancel()
        sweepTask = nil
        pendingTrigger = nil
        timer?.invalidate()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers.removeAll()
    }

    /// One canonical pass across profiles, including shared Favorites only once.
    /// Internal so deterministic clock tests can exercise the real unload path.
    func evaluate(_ trigger: TabSuspension.Trigger) async {
        lastSweepUnloadedCount = 0
        updateClocks()
        if trigger != .idle {
            TabSnapshotStore.shared.clear()
            let now = uptime()
            if TabSuspension.shouldPurgeMemoryCache(now: now, lastPurge: lastMemoryCachePurge) {
                lastMemoryCachePurge = now
                let stores = RAMCacheManager.shared.storesProvider?().map(\.1) ?? [WKWebsiteDataStore.default()]
                Task { @MainActor in
                    var seen: Set<ObjectIdentifier> = []
                    for store in stores where seen.insert(ObjectIdentifier(store)).inserted {
                        await store.removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast)
                    }
                }
            }
        }
        sweepResources = Dictionary(TabResourceMonitor.shared.sampleAllTabs(in: session).map { ($0.tabId, $0) }, uniquingKeysWith: { first, _ in first })
        archiveIfDue(trigger)
        let candidates = candidateIDs(trigger)
        let priority = Dictionary(uniqueKeysWithValues: budgetPriority.enumerated().map { ($0.element, $0.offset) })
        let tabs = session.allTabs.filter { candidates.contains($0.id) }.sorted {
            (priority[$0.id] ?? Int.max) < (priority[$1.id] ?? Int.max)
        }
        var visited: Set<Tab.ID> = []
        for tab in tabs {
            guard !Task.isCancelled else { return }
            guard visited.insert(tab.id).inserted else { continue }
            var group: Set<Tab.ID> = [tab.id]
            for cohort in session.splitCohorts where cohort.contains(tab.id) { group.formUnion(cohort) }
            let members = session.allTabs.filter { group.contains($0.id) && $0.isLoaded }
            visited.formUnion(group)
            guard members.allSatisfy({ candidates.contains($0.id) }) else { continue }
            let remaining = candidateIDs(trigger)
            guard members.allSatisfy({ remaining.contains($0.id) }) else { continue }
            let revision = visibilityRevision
            var safe = true
            var checkedViews: [Tab.ID: WKWebView] = [:]
            for member in members {
                guard member.allowsAutomaticHibernation, let view = member.currentWebView,
                      !protectsTransfer(view), await inspectPage(view),
                      member.currentWebView === view else { safe = false; break }
                checkedViews[member.id] = view
            }
            // Revalidate after all asynchronous checks. Switching back or
            // changing a split cancels a stale decision before any view is removed.
            updateClocks()
            let current = candidateIDs(trigger)
            guard safe, !Task.isCancelled, revision == visibilityRevision,
                  members.allSatisfy({ member in
                      guard current.contains(member.id), member.allowsAutomaticHibernation,
                            let view = checkedViews[member.id], member.currentWebView === view else { return false }
                      return !protectsTransfer(view) && validatePage(view)
                  }) else { continue }
            for member in members {
                if let view = member.currentWebView { member.retainHibernationViewport(PageHibernationGuard.shared.capturedViewport(of:view)) }
            }
            session.suspend(members)
            lastSweepUnloadedCount += members.count
            await Task.yield()
        }
        if !Task.isCancelled, let delay = settings.profileHibernationDelay {
            await WebPanelViewController.hibernateHiddenPanels(after: delay)
        }
        Metrics.log("sweep trigger=\(trigger) unloaded=\(lastSweepUnloadedCount) loaded=\(session.allTabs.count { $0.isLoaded })")
    }

    private func candidateIDs(_ trigger: TabSuspension.Trigger) -> Set<Tab.ID> {
        let now = uptime()
        let tabs = session.allTabs
        var protected = session.visibleTabIDs
        for tab in tabs where tab.isLoaded {
            guard let view = tab.currentWebView else { continue }
            if !tab.allowsAutomaticHibernation || protectsTransfer(view)
                || (view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor) {
                protected.insert(tab.id)
            }
        }
        let stamp = Date(timeIntervalSinceReferenceDate: now)
        let allStates = tabs.map { tab -> TabSuspension.TabState in
            var state = TabSuspension.TabState(id: tab.id, isLoaded: tab.isLoaded,
                lastActiveAt: stamp.addingTimeInterval(-clock.tabIdle(tab.id, now: now)), keepsAwake: tab.keepsAwake)
            if let usage = sweepResources[tab.id] {
                state.footprint = usage.hasMeasuredMemory ? usage.memoryBytes : nil
                state.processID = usage.pid
                state.sharedProcess = usage.processPageCount > 1
            }
            return state
        }
        budgetPriority = TabSuspension.budgetOrder(among: allStates, protecting: protected,
            budget: settings.backgroundMemoryBudget, cohorts: session.splitCohorts, now: stamp)
        var chosen = Set(budgetPriority)
        for profile in session.profiles {
            let members = tabs.filter { $0.identity == profile.identity }
            let tabDelay = profile.preferences.sleepMinutes.map { $0 > 0 ? Double($0) * 60 : nil } ?? settings.tabSuspensionDelay
            var threshold = tabDelay
            if let profileDelay = settings.profileHibernationDelay,
               !clock.visibleProfiles.contains(profile.identity),
               clock.profileIdle(profile.identity, now: now) >= profileDelay {
                threshold = min(tabDelay ?? profileDelay, profileDelay)
            }
            let stamp = Date(timeIntervalSinceReferenceDate: now)
            let memberIDs = Set(members.map(\.id))
            let states = allStates.filter { memberIDs.contains($0.id) }
            chosen.formUnion(TabSuspension.candidateIDs(among: states, protecting: protected,
                idleThreshold: threshold, trigger: trigger, cohorts: session.splitCohorts, now: stamp))
        }
        return chosen
    }

    /// The second stage, run off the same sweep.
    ///
    /// Only on `.idle`. Memory pressure is a reason to release a page, never a
    /// reason to take a row out of the sidebar: the user would lose tabs
    /// because something else on their Mac asked for memory, which is not a
    /// sentence that should ever be true.
    ///
    /// Run before unloading this sweep's candidates. Only pages already asleep
    /// at the beginning of the sweep can be archived; newly unloaded pages are
    /// considered on a later sweep.
    private func archiveIfDue(_ trigger: TabSuspension.Trigger) {
        guard trigger == .idle else { return }
        for space in session.spaces {
            guard !space.isPrivate else { continue }
            let hours = space.archiveHours ?? settings.tabArchiveHours
            guard hours > 0 else { continue }
            let threshold = TimeInterval(hours) * 3_600
            let stale = TabArchiving.candidates(
                among: space.tabs,
                protecting: session.visibleTabIDs,
                threshold: threshold,
                isPinned: { [session] in session.isPinned($0) },
                isProviderManaged: { [session] in session.isInLiveFolder($0) },
                cohorts: session.splitCohorts
            )
            guard !stale.isEmpty else { continue }
            session.archive(stale)
        }
    }
}
