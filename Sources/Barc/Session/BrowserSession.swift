// Modified for Barc: Arc import, session restoration and profile isolation, 2026-10-23.
// Modified for Barc: nested folder duplication and promotion with profile preservation, 2026-10-24.
import AppKit
import Combine
import WebKit

/// The browser's model root: every Space, every Tab, and which of each is
/// showing. It is the only place the model is mutated, so it is also the only
/// place changes are announced, and the seam where persistence plugs in.
///
/// Views subscribe to `changes` and refresh the smallest thing they can. A
/// coarse `objectWillChange`-style signal would reload the whole sidebar on
/// every keystroke of a page title.
@MainActor
final class BrowserSession {
    /// Private query choices live only for this session, never in preferences.
    private var privateFolderCommands: [UUID:FolderCommandHistory] = [:]
    enum Change {
        /// The set of spaces, or which space is active, changed.
        case spaces
        /// The active space's tab list changed (added, removed, reordered).
        case tabs
        /// A different tab became active.
        case activeTab
        /// One tab's displayed state changed.
        case tab(Tab)
        /// The bookmark list changed.
        case bookmarks
        /// A tab group or a pinned site changed. The sidebar's structure, not
        /// just its contents, has to be rebuilt.
        case structure
    }

    let changes = PassthroughSubject<Change, Never>()

    /// How the session tells the user something happened somewhere they are not
    /// looking. Set by the window; nil in tests and before a window exists, so
    /// a toast stays a side effect the model can do without.
    var showToast: ((Toast) -> Void)?

    /// A page finished loading in a tab. Fired before history decides whether
    /// to record it, so rules see private tabs too.
    var onVisit: ((Tab, URL) -> Void)?

    /// Rules that decide which space a URL opens in. Loaded once; inert until
    /// the user writes a rule.
    let routing = SpaceRoutingService()

    /// Keeps live folders' contents up to date. Owned here because the sidebar
    /// draws its state and the application services its requests, and both need
    /// the same instance.
    let liveFolders = LiveFolderManager()

    private(set) var spaces: [Space] = []
    private(set) var profiles: [BrowserProfile] = []
    private(set) var activeSpaceID: Space.ID
    private(set) var bookmarks: [Bookmark] = []

    private let mainDatabase: BrowserDatabase?
    private var identityDatabases: [Space.Identity: BrowserDatabase] = [:]
    private var database: BrowserDatabase? { database(for: activeSpace.identity) }

    /// Profiles have separate history and bookmarks as well as website stores.
    /// A failed profile database must never fall back to another identity's data.
    func database(for identity: Space.Identity) -> BrowserDatabase? {
        guard let mainDatabase, !identity.isPrivate else { return nil }
        if identity == .standard { return mainDatabase }
        if let cached = identityDatabases[identity] { return cached }
        guard case .isolated(let id) = identity else { return nil }
        let directory = mainDatabase.fileURL.deletingLastPathComponent().appending(path: "Profiles/" + id.uuidString.lowercased())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let created = try BrowserDatabase(path: directory.appending(path: "browser.sqlite"))
            identityDatabases[identity] = created
            return created
        } catch {
            return nil
        }
    }
    private let sessionStore: SessionStore
    private let settings: Settings
    private var tabSubscriptions: [Tab.ID: AnyCancellable] = [:]
    private struct SplitUndoState: Sendable {
        let spaceID: Space.ID
        let splits: SplitCollection
        let activeTabID: Tab.ID?
    }
    private var lastSplitUndoState: SplitUndoState?
    private var saveTask: Task<Void, Never>?

    /// Writing on every keystroke of a page title would be wasteful; a short
    /// delay collapses a burst of changes into one write.
    private static let saveDelay = Duration.seconds(1)

    init(database: BrowserDatabase?, sessionStore: SessionStore = SessionStore(), settings: Settings = .shared) {
        self.mainDatabase = database
        self.sessionStore = sessionStore
        self.settings = settings

        let restored = settings.restoresSession ? sessionStore.load() : nil

        if let restored, let spaces = Self.spaces(from: restored), !spaces.isEmpty {
            self.spaces = spaces
            let index = min(max(restored.activeSpaceIndex, 0), spaces.count - 1)
            self.activeSpaceID = spaces[index].id
            // The archive is filed by space, and a snapshot names spaces by
            // position -- `spaces(from:)` maps one to one, so zipping is the
            // pairing, and a space that somehow did not come back takes its
            // archive with it rather than orphaning the records onto another.
            self.archivedTabs = zip(spaces, restored.spaces).flatMap { space, stored in
                (stored.archivedTabs ?? []).map {
                    ArchivedTab(snapshot: $0.tab, spaceID: space.id, archivedAt: $0.archivedAt)
                }
            }
            for space in spaces {
                for tab in space.tabs { adopt(tab) }
                // A private space is saved without its tabs, so it comes back
                // with one fresh one rather than as an empty list.
                if space.tabs.isEmpty {
                    insert(Tab(url: settings.newTabURL(isPrivate: space.isPrivate), identity: space.identity), into: space, at: 0, select: true)
                }
            }
        } else {
            // The first space keeps WebKit's default store, so anything browsed
            // before spaces had their own identity is still signed in.
            let personal = Space(name: "Personal", identity: .standard, theme: .blue)
            self.spaces = [personal]
            self.activeSpaceID = personal.id
            newTab()
        }

        profiles = Self.profileList(from: restored, spaces: self.spaces)
        for profile in profiles { for tab in profile.favoriteTabs { adopt(tab) } }
        liveFolders.delegate = self
        loadBookmarks()

        NetworkConfigManager.shared.spaceProxyResolver = { [weak self] identity in
            self?.profiles.first(where: { $0.identity == identity })?.preferences.customProxy
        }
        // A tab knows its identity, not its space; this is how it asks for
        // the space's user agent and starting zoom.
        Tab.spaceOverrides = { [weak self] identity in
            guard let profile = self?.profiles.first(where: { $0.identity == identity }) else { return nil }
            return Tab.SpaceOverrides(userAgent: profile.preferences.userAgent, defaultZoom: profile.preferences.defaultZoom)
        }
    }

    // MARK: - Spaces

    var activeSpace: Space {
        spaces.first { $0.id == activeSpaceID } ?? spaces[0]
    }

    var activeTab: Tab? { activeSpace.activeTab }

    @discardableResult
    func addProfile(named name: String) -> BrowserProfile? {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty else { return nil }
        let profile = BrowserProfile(name: name, identity: .makeIsolated())
        profile.hasCustomName = true
        profiles.append(profile)
        changes.send(.spaces)
        scheduleSave()
        return profile
    }

    func renameProfile(_ profile: BrowserProfile, to rawName: String) {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard profiles.contains(where: { $0 === profile }), !name.isEmpty, name != profile.name else { return }
        profile.name = name
        profile.hasCustomName = true
        changes.send(.spaces)
        scheduleSave()
    }

    /// Rebinds the layout's pages to an existing identity. WebKit state never
    /// crosses the profile seam: the old profile keeps its data and Favorites.
    @discardableResult
    func assignProfile(_ profile: BrowserProfile, to space: Space) -> Bool {
        guard spaces.contains(where: { $0 === space }), profiles.contains(where: { $0 === profile }),
              !space.isPrivate, !profile.identity.isPrivate, space.profile !== profile else { return false }
        let oldProfile = space.profile
        // Recently closed and archived pages also belong to their old login
        // context. Retain their URLs and metadata, never its opaque WebKit state.
        closedTabs = closedTabs.map { record in
            guard record.spaceID == space.id else { return record }
            var stored = record.snapshot; stored.interactionState = nil
            return ClosedTab(id: record.id, snapshot: stored, spaceID: record.spaceID, closedAt: record.closedAt)
        }
        closedWindows = closedWindows.map { record in
            guard record.spaceID == space.id else { return record }
            let tabs = record.tabs.map { stored in var copy = stored; copy.interactionState = nil; return copy }
            return ClosedWindow(id: record.id, title: record.title, spaceID: record.spaceID, tabs: tabs, closedAt: record.closedAt)
        }
        for index in archivedTabs.indices where archivedTabs[index].spaceID == space.id {
            archivedTabs[index].snapshot.interactionState = nil
        }
        let selected = space.workspaceTabs.firstIndex { $0.id == space.activeTabID }
        let snapshots = space.workspaceTabs.map { tab -> SessionSnapshot.Tab in
            var stored = tab.snapshot()
            stored.interactionState = nil
            return stored
        }
        for tab in space.workspaceTabs { _ = space.remove(tab); forget(tab) }
        space.useProfile(profile)
        for stored in snapshots {
            let tab = Tab(restoring: stored, identity: profile.identity); adopt(tab)
            space.insert(tab, at: space.workspaceTabs.count)
        }
        if space.workspaceTabs.isEmpty {
            let tab = Tab(url: settings.newTabURL(isPrivate: false), identity: profile.identity); adopt(tab)
            space.insert(tab, at: 0); space.setActiveTabID(tab.id)
        } else { space.setActiveTabID(space.workspaceTabs[min(selected ?? 0, space.workspaceTabs.count - 1)].id) }
        space.splits = SplitCollection()
        if !spaces.contains(where: { $0.profile === oldProfile }) {
            for tab in oldProfile.favoriteTabs { tab.unload() }
        }
        if activeSpace === space { bookmarks = []; changes.send(.bookmarks); loadBookmarks() }
        changes.send(.spaces); changes.send(.structure); changes.send(.tabs); changes.send(.activeTab)
        scheduleSave()
        return true
    }

    private func space(containing tab: Tab) -> Space? {
        if activeSpace.index(of: tab) != nil { return activeSpace }
        return spaces.first { $0.index(of: tab) != nil }
    }

    private func repairSelections(for profile: BrowserProfile) {
        for space in spaces where space.profile === profile {
            if space.tabs.isEmpty {
                insert(Tab(url: settings.newTabURL(isPrivate: space.isPrivate), identity: profile.identity), into: space, at: 0, select: true)
            } else if space.activeTab == nil { space.setActiveTabID(space.tabs.first?.id) }
        }
    }

    private static func profileList(from snapshot: SessionSnapshot?, spaces: [Space]) -> [BrowserProfile] {
        var result: [BrowserProfile] = []
        for space in spaces where !result.contains(where: { $0.identity == space.identity }) { result.append(space.profile) }
        for stored in snapshot?.profiles ?? [] {
            let profile = BrowserProfile.restore(stored)
            if !result.contains(where: { $0.identity == profile.identity }) { result.append(profile) }
        }
        return result
    }

    private func reconcileProfiles() {
        for space in spaces {
            if let existing = profiles.first(where: { $0.identity == space.identity }) {
                guard existing !== space.profile else { continue }
                let activeFavorite = space.activeTab?.pinnedSiteID == nil ? nil : space.activeTab
                let incomingFavorites = space.profile.favoriteTabs
                existing.mergeFavorites(from: space.profile)
                space.useProfile(existing)
                // Coalesce identical old copies. If a copy was on another
                // page or had different notes, keep it as an ordinary tab.
                for tab in incomingFavorites { space.insert(tab, at: space.workspaceTabs.count) }
                if let pinID = activeFavorite?.pinnedSiteID, let tab = existing.favoriteTabs.first(where: { $0.pinnedSiteID == pinID }) { space.setActiveTabID(tab.id) }
            } else { profiles.append(space.profile) }
        }
        let liveIDs = Set(allTabs.map(\.id))
        for id in Array(tabSubscriptions.keys) where !liveIDs.contains(id) { tabSubscriptions[id] = nil }
        for space in spaces where space.look.favoritesHintDismissed && space.profile.preferences.favoritesHintDismissed == nil {
            space.profile.preferences.favoritesHintDismissed = true
        }
    }

    func dismissFavoritesHint(in space: Space) {
        guard spaces.contains(where: { $0 === space }), space.profile.preferences.favoritesHintDismissed != true else { return }
        space.profile.preferences.favoritesHintDismissed = true
        changes.send(.structure)
        scheduleSave()
    }

    @discardableResult
    func enrichArcFavoritesHint(_ dismissed: Bool, for identity: Space.Identity) -> Bool {
        guard !identity.isPrivate, let profile = profiles.first(where: { $0.identity == identity }),
              profile.preferences.favoritesHintDismissed == nil else { return false }
        profile.preferences.favoritesHintDismissed = dismissed
        changes.send(.structure)
        scheduleSave()
        return true
    }

    /// Adds a space with an identity of its own: fresh cookies, no logins.
    ///
    /// - Parameters:
    ///   - isPrivate: nothing the space browses is written to disk, and its
    ///     tabs are not saved.
    ///   - theme: the colour, or nil for the next one no space is using, so
    ///     two spaces made in a row are told apart without a visit to Settings.
    @discardableResult
    func addSpace(
        named name: String,
        isPrivate: Bool = false,
        theme: SpaceTheme? = nil,
        icon: SpaceIcon = .automatic,
        profile: BrowserProfile? = nil
    ) -> Space {
        // Held to the limit here rather than at each caller: a name reaches
        // this from a sheet, from Settings, from the menu bar and from the
        // companion iPhone, and only one of those is a text field we control.
        let existing = !isPrivate ? profile.flatMap { candidate in profiles.first { $0 === candidate && !$0.identity.isPrivate } } : nil
        let space = Space(
            name: Space.clampName(name),
            identity: existing?.identity ?? (isPrivate ? .makeEphemeral() : .makeIsolated()),
            profile: existing,
            theme: theme ?? nextUnusedTheme()
        )
        space.icon = icon
        spaces.append(space)
        if !profiles.contains(where: { $0 === space.profile }) { profiles.append(space.profile) }
        activeSpaceID = space.id
        changes.send(.spaces)
        newTab()
        return space
    }

    /// The first colour in the palette that no space has, or the default when
    /// every one is taken. `neutral` is an opt-out rather than a colour, so it
    /// is never handed out.
    func nextUnusedTheme() -> SpaceTheme {
        let taken = Set(spaces.map(\.theme))
        return SpaceTheme.palette.first { $0 != .neutral && !taken.contains($0) } ?? .default
    }

    /// Puts an emoji, a symbol or a picture on a space -- or takes it off.
    ///
    /// The picture the space was carrying is deleted as it is replaced. These
    /// files are owned by the icon that names them and referred to by nothing
    /// else, so one no space points at is a file nothing will ever draw.
    func setIcon(_ icon: SpaceIcon, for space: Space) {
        let alreadyCustomized = space.look.spaceIconWasCustomized
        space.look.spaceIconWasCustomized = true
        guard space.icon != icon else {
            if !alreadyCustomized { scheduleSave() }
            return
        }
        if let old = space.icon.customFileName, old != icon.customFileName {
            SpaceIconStore.shared.remove(named: old)
        }
        space.icon = icon
        changes.send(.spaces)
        scheduleSave()
    }

    /// Recolours a space. Every window showing it repaints, which is the whole
    /// point of the setting, so this reports through `.spaces` exactly as a
    /// rename does.
    func setTheme(_ theme: SpaceTheme, for space: Space) {
        // Picking a solid swatch clears a gradient: they are the same setting,
        // and the swatch is the later word.
        let clearsGradient = space.look.gradient != nil
        guard theme != space.theme || clearsGradient || space.look.importedChrome != nil || space.look.sidebarTheme != nil else { return }
        space.theme = theme
        if clearsGradient || space.look.importedChrome != nil || space.look.sidebarTheme != nil {
            var look = space.look
            look.sidebarTheme = nil
            look.gradient = nil
            look.importedChrome = nil
            look.importedChromeWasCustomized = true
            space.look = look
        }
        changes.send(.spaces)
        scheduleSave()
    }

    /// Changes the rim a space draws around the window. Reported the same
    /// way as a recolour, for the same reason.
    func setBorder(_ border: WindowBorder, for space: Space) {
        guard border != space.border else { return }
        space.border = border
        changes.send(.spaces)
        scheduleSave()
    }

    /// Changes how a space looks and behaves. A change of fonts reaches the
    /// space's open pages at once, and every page made for it from now on.
    func setLook(_ look: SpaceLook, for space: Space) {
        guard look != space.look else { return }
        var look = look
        if look.importedChrome == space.look.importedChrome,
           look.customColorHex != space.look.customColorHex || look.gradient != space.look.gradient {
            look.importedChrome = nil
            look.importedChromeWasCustomized = true
        }
        if look.sidebarTheme == space.look.sidebarTheme,
           look.customColorHex != space.look.customColorHex || look.gradient != space.look.gradient { look.sidebarTheme = nil }
        let fontsChanged = look.fonts != space.look.fonts
        space.look = look
        if fontsChanged {
            WebEnvironment.shared.setFonts(look.fonts, for: space.identity)
            for tab in space.tabs { tab.applyFonts(look.fonts) }
        }
        changes.send(.spaces)
        scheduleSave()
    }

    /// Washes a space with a gradient, or clears it back to the solid theme.
    /// The gradient supersedes the theme colour wherever the chrome is washed.
    func setSpaceGradient(_ gradient: SpaceGradient?, for space: Space) {
        guard space.look.gradient != gradient || space.look.sidebarTheme != nil else { return }
        var look = space.look
        look.sidebarTheme = nil
        look.gradient = gradient
        look.importedChrome = nil
        look.importedChromeWasCustomized = true
        space.look = look
        changes.send(.spaces)
        scheduleSave()
    }

    /// A custom colour is a theme of its own; picking one selects it. A solid
    /// colour also clears any gradient, since the two are the same setting seen
    /// two ways and the last one picked is the one meant.
    func setCustomColor(_ color: NSColor, for space: Space) {
        var look = space.look
        look.sidebarTheme = nil
        look.customColor = color
        look.gradient = nil
        look.importedChrome = nil
        look.importedChromeWasCustomized = true
        space.look = look
        space.theme = .custom
        changes.send(.spaces)
        scheduleSave()
    }

    var browserAppearance: AppearancePreference { settings.appearance }

    /// Arc's theme appearance buttons choose the whole browser's appearance.
    func setBrowserAppearance(_ appearance: AppearancePreference) {
        settings.appearance = appearance
        let dark = appearance == .dark || (appearance == .system && UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
        for space in spaces {
            space.look.appearance = appearance
            if let chrome = space.look.importedChrome {
                space.look.importedChrome = ImportedChrome(color: chrome.color, intensity: chrome.intensity, noise: chrome.noise,
                    usesDarkText: !dark, usesLightMaterial: !dark, lightFocus: chrome.lightFocus, darkFocus: chrome.darkFocus,
                    lightSubtitle: chrome.lightSubtitle, darkSubtitle: chrome.darkSubtitle)
            }
        }
        changes.send(.spaces)
        scheduleSave()
    }

    func setSidebarTheme(_ style: SidebarThemeStyle, for space: Space) {
        guard spaces.contains(where: { $0 === space }) else { return }
        let style = SidebarThemeStyle(colors: style.colors, intensity: style.intensity, grain: style.grain, hasGrain: style.hasGrain)
        guard space.look.sidebarTheme != style else { return }
        space.theme = style.colors.isEmpty ? .neutral : .custom
        space.look.sidebarTheme = style
        space.look.customColorHex = style.colors.first?.nsColor.hexString
        space.look.gradient = nil
        space.look.importedChrome = nil
        space.look.importedChromeWasCustomized = true
        space.look.washOpacity = 1
        changes.send(.spaces)
        scheduleSave()
    }

    func rename(_ space: Space, to name: String) {
        let trimmed = Space.clampName(name)
        guard !trimmed.isEmpty, trimmed != space.name else { return }
        space.name = trimmed
        changes.send(.spaces)
        scheduleSave()
    }

    func setDownloadsDirectoryPath(_ path: String?, for space: Space) {
        guard path != space.downloadsDirectoryPath else { return }
        space.downloadsDirectoryPath = path
        changes.send(.spaces)
        scheduleSave()
    }

    func setBookmarkFolder(_ folder: String?, for space: Space) {
        guard folder != space.bookmarkFolder else { return }
        space.bookmarkFolder = folder
        changes.send(.spaces)
        scheduleSave()
    }

    func setEnabledExtensionIDs(_ ids: Set<UUID>?, for space: Space) {
        guard ids != space.enabledExtensionIDs else { return }
        space.enabledExtensionIDs = ids
        changes.send(.spaces)
        scheduleSave()
    }

    func setPasswordVaultAccount(_ account: String?, for space: Space) {
        guard account != space.passwordVaultAccount else { return }
        space.passwordVaultAccount = account
        changes.send(.spaces)
        scheduleSave()
    }

    /// The engine this space searches with: its own, or the one in Settings.
    func searchEngine(for space: Space) -> SearchEngine {
        if let id = space.searchEngineID, let engine = settings.searchEngines.first(where: { $0.id == id }) {
            return engine
        }
        return settings.searchEngine(isPrivate: space.isPrivate)
    }

    func setSearchEngineID(_ id: String?, for space: Space) {
        guard id != space.searchEngineID else { return }
        space.searchEngineID = id
        changes.send(.spaces)
        scheduleSave()
    }

    func setUserAgent(_ userAgent: String?, for space: Space) {
        let trimmed = userAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard value != space.userAgent else { return }
        space.userAgent = value
        changes.send(.spaces)
        scheduleSave()
    }

    func setSleepMinutes(_ minutes: Int?, for space: Space) {
        guard minutes != space.sleepMinutes else { return }
        space.sleepMinutes = minutes
        changes.send(.spaces)
        scheduleSave()
    }

    func setDefaultZoom(_ zoom: String?, for space: Space) {
        guard zoom != space.defaultZoom else { return }
        space.defaultZoom = zoom
        changes.send(.spaces)
        scheduleSave()
    }

    func setCustomProxy(_ proxy: ProxySettings?, for space: Space) {
        guard proxy != space.customProxy else { return }
        space.customProxy = proxy
        changes.send(.spaces)
        scheduleSave()
        NetworkConfigManager.shared.applyToAllStores()
    }

    /// Closing a Space removes its layout and ordinary tabs. Its profile and
    /// shared Favorites remain available to other Spaces and future layouts.
    func removeSpace(_ space: Space) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        let previousIdentity = activeSpace.identity
        for tab in space.workspaceTabs { forget(tab) }
        // ...and so does the picture it was wearing, for the same reason: the
        // file is the icon's, and the icon is going.
        if let fileName = space.icon.customFileName {
            SpaceIconStore.shared.remove(named: fileName)
        }
        // Its archive goes with it. The records are filed by space id, so ones
        // left behind by a deleted space are unreachable -- no list will ever
        // show them and nothing can restore them -- while still counting
        // against that space's cap if its id ever came back.
        archivedTabs.removeAll { $0.spaceID == space.id }
        space.splits = SplitCollection()
        spaces.remove(at: index)
        routing.removeRoutes(toSpacesNotIn: Set(spaces.map(\.id)))
        if activeSpaceID == space.id {
            activeSpaceID = spaces[min(index, spaces.count - 1)].id
        }
        if activeSpace.identity != previousIdentity {
            bookmarks = []
            changes.send(.bookmarks)
            loadBookmarks()
        }

        if !spaces.contains(where: { $0.identity == space.identity }) {
            // A profile outlives its last Space. Free page processes, retain
            // the profile's cookies, history, passwords and saved Favorites.
            for tab in space.profile.favoriteTabs { tab.unload() }
            if space.isPrivate {
                profiles.removeAll { $0 === space.profile }
                WebEnvironment.shared.releaseDataStore(for: space.identity)
            }
        }

        changes.send(.spaces)
        changes.send(.tabs)
        changes.send(.activeTab)
        scheduleSave()
    }

    func selectSpace(_ space: Space) {
        guard space.id != activeSpaceID, spaces.contains(where: { $0.id == space.id }) else { return }
        if settings.autoPictureInPicture {
            if let prevTab = activeSpace.activeTab, prevTab.hasPlayingVideo, !prevTab.isInPictureInPicture {
                prevTab.requestPictureInPicture(autoTriggered: true)
            }
            if let nextTab = space.activeTab, nextTab.wasAutoPictureInPicture, nextTab.isInPictureInPicture {
                nextTab.exitPictureInPicture()
            }
        }
        let previousIdentity = activeSpace.identity
        activeSpaceID = space.id
        if previousIdentity != space.identity { bookmarks = []; changes.send(.bookmarks) }
        loadBookmarks()
        changes.send(.spaces)
        changes.send(.tabs)
        changes.send(.activeTab)
        scheduleSave()
    }

    func selectSpace(offsetBy offset: Int) {
        let visible = sidebarSpaces
        guard visible.count > 1,
              let index = visible.firstIndex(where: { $0.id == activeSpaceID }) else { return }
        let wrapped = (index + offset % visible.count + visible.count) % visible.count
        selectSpace(visible[wrapped])
    }

    /// Hidden Spaces keep their data and remain available in the Library. A
    /// Space opened from there stays in the dock until the user leaves it.
    var sidebarSpaces: [Space] { spaces.filter { $0.look.showsInDock || $0.id == activeSpaceID } }

    @discardableResult
    func setDockVisible(_ visible: Bool, for space: Space) -> Bool {
        guard spaces.contains(where: { $0 === space }) else { return false }
        let next = spaces.first { $0 !== space && $0.look.showsInDock }
        guard visible || next != nil else { return false }
        var look = space.look
        look.showsInDock = visible
        look.dockVisibilityWasCustomized = true
        setLook(look,for:space)
        if !visible, space.id == activeSpaceID, let next { selectSpace(next) }
        return true
    }

    // MARK: - Tabs

    /// Creates a tab in the active space. The web view is not built until the
    /// tab is shown, so an unselected new tab costs a few hundred bytes.
    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true, origin: SpaceRouter.Origin = .inBrowser) -> Tab {
        let target = url ?? settings.newTabURL(isPrivate: activeSpace.isPrivate)
        let space = routedSpace(for: target, origin: origin) ?? activeSpace
        let tab = Tab(url: target, identity: space.identity)
        insert(tab, into: space, at: space.tabs.count, select: select)

        guard space.id != activeSpaceID else { return tab }
        // A routed tab the user asked to see takes them to it; one opened in
        // the background says where it went instead.
        if select {
            selectSpace(space)
        } else {
            announceRouted(tab, to: space)
        }
        return tab
    }

    /// Resetting a Space pin keeps its identity and saved address. Command-click
    /// also keeps the departing page in Today, in that same Space and profile.
    @discardableResult
    func resetSidebarPin(_ tab: Tab, keepingCurrentPage: Bool = false) -> Bool {
        guard canResetSidebarPin(tab), let owner = sidebarOwner(of: tab),
              let savedURL = tab.pinnedPageURL else { return false }
        if keepingCurrentPage {
            let previous = Tab(url: tab.url, identity: owner.identity)
            // Domain routing is for newly requested destinations. This page
            // already belongs to the pin's profile and must remain there.
            insert(previous, into: owner, at: owner.tabs.count, select: false)
        }
        selectSpace(owner)
        selectTab(tab)
        tab.load(savedURL)
        return true
    }

    private func routedSpace(for url: URL, origin: SpaceRouter.Origin) -> Space? {
        guard case .route(let id) = routing.decision(
            for: url,
            context: .newTab(origin),
            currentSpaceID: activeSpaceID,
            knownSpaceIDs: Set(spaces.map(\.id))
        ) else { return nil }
        return spaces.first { $0.id == id }
    }

    private func announceRouted(_ tab: Tab, to space: Space) {
        guard ToastPreferences.shared.showsRoutedTabToast else { return }
        showToast?(Toast.routed(to: space.name) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.selectSpace(space)
            self.selectTab(tab)
        })
    }

    /// Commits a rename from the sidebar's inline editor. An empty value clears
    /// the name and the tab falls back to its page title.
    /// Tags a tab with a colour, or clears it.
    func setColorTag(_ tag: TabColorTag?, for tab: Tab) {
        tab.setColorTag(tag)
    }

    func rename(_ tab: Tab, to name: String) {
        let outcome = TabNameStore.shared.rename(tab.id, to: name)
        guard outcome != .unchanged else { return }
        // The tab's own change signal drives both the sidebar row and the save.
        tab.didChange.send()
        if let toast = Toast.rename(outcome, restoredTitle: tab.displayTitle) {
            showToast?(toast)
        }
    }

    /// Adopts a web view WebKit created for `window.open`, placing it next to
    /// the tab that opened it.
    func adoptChildTab(of parent: Tab, configuration: WKWebViewConfiguration) -> Tab {
        let space = space(containing: parent) ?? activeSpace
        let webView = WebEnvironment.shared.makeWebView(configuration: configuration)
        let tab = Tab(adopting: webView, identity: space.identity)
        let index = space.index(of: parent).map { $0 + 1 } ?? space.tabs.count
        insert(tab, into: space, at: index, select: space.id == activeSpaceID)
        return tab
    }

    /// Adopts a web view a glance has already loaded, as a tab of its own.
    ///
    /// The page is live: nothing reloads, nothing is restored from
    /// `interactionState`, and the scroll position the user reached inside the
    /// glance is where the tab opens.
    @discardableResult
    func adoptGlancedTab(_ webView: WKWebView, after parent: Tab?) -> Tab {
        let space = parent.flatMap { self.space(containing: $0) } ?? activeSpace
        let tab = Tab(adopting: webView, identity: space.identity)
        let index = parent.flatMap { space.index(of: $0) }.map { $0 + 1 } ?? space.tabs.count
        insert(tab, into: space, at: index, select: space.id == activeSpaceID)
        return tab
    }

    /// Adopts the page a Little Arc window was showing, as a tab of the space
    /// the user kept it in.
    ///
    /// The live web view is adopted only when the destination is the space it
    /// was loaded in. Anywhere else the page opens fresh, because a web view is
    /// bound to a data store when it is created: carrying one across spaces
    /// would put one space's cookies on another space's tab, which is exactly
    /// what spaces exist to prevent. So a page kept in a different space loads
    /// again there, signed in as that space -- which is what "move this to
    /// Personal" has to mean.
    @discardableResult
    func adoptLittleArcPage(
        _ webView: WKWebView,
        loadedAs identity: Space.Identity,
        url: URL,
        into space: Space
    ) -> Tab {
        let tab = space.identity == identity
            ? Tab(adopting: webView, identity: identity)
            : Tab(url: url, identity: space.identity)
        insert(tab, into: space, at: space.tabs.count, select: true)
        // Kept means the page is in the sidebar now, so the user is shown it:
        // the little window is gone and this is where the page went.
        if space.id != activeSpaceID { selectSpace(space) }
        return tab
    }

    /// Whether an address is one of the active space's pinned sites. Glance's
    /// off-site rule asks this; it ships switched off.
    func isPinnedSite(_ url: URL) -> Bool {
        activeSpace.pinnedSites.contains { $0.matches(url) }
    }

    /// Closes a tab, unless it is locked.
    ///
    /// The one door every close goes through -- the cross on the row, Cmd-W,
    /// the context menu, "Close Other Tabs", an extension -- which is what
    /// makes one `guard` enough to keep the promise the lock made. Returns
    /// false when the lock refused, so a close the user aimed at a single tab
    /// can say so while a sweep over many simply steps around it.
    @discardableResult
    func closeTab(_ tab: Tab) -> Bool {
        guard !tab.isLocked else { return false }
        guard let space = space(containing: tab) else { return false }
        let wasFavorite = tab.pinnedSiteID != nil
        remember(closing: tab, in: space)
        // A live folder must not offer the item again on its next poll.
        if let groupID = tab.groupID {
            liveFolders.tabWasRemoved(tab.id, fromFolder: groupID)
        }
        let tabURL = tab.url
        // The page that would have answered a click on one of its notifications
        // is about to stop existing, so its notifications leave the screen with
        // it. A service worker's are left alone: outliving the page is the
        // whole reason a site posts them that way.
        WebNotificationCentre.shared.forget(tabID: tab.id)
        detach(tab, from: space)
        if wasFavorite { repairSelections(for: space.profile) }
        forgetDataIfNeeded(for: tabURL, in: space)
        return true
    }

    /// Tells the user a lock stopped a close they asked for, and offers to lift
    /// it. Silence would read as a broken close button; an alert would be a
    /// heavier interruption than the mis-hit Cmd-W that usually causes this.
    func reportCloseRefused(_ tab: Tab) {
        showToast?(.closeRefused(tab: tab.displayTitle, unlock: { [weak tab] in
            guard let tab else { return }
            tab.setLocked(false)
            self.closeTab(tab)
        }))
    }

    private func forgetDataIfNeeded(for url: URL, in space: Space) {
        guard let identity = identityToForgetAfterClosing(url, in: space), let host = url.host() else { return }
        Task { await WebsiteData.removeData(forHost: SiteSettingsState.normalise(host), in: [identity]) }
    }

    /// Closing a site affects only its profile, after its last page is gone
    /// from every Space sharing that profile.
    func identityToForgetAfterClosing(_ url: URL, in space: Space) -> Space.Identity? {
        guard let host = url.host(), !host.isEmpty else { return nil }
        guard SiteSettings.shared.forgetsWhenClosed(for: url) else { return nil }
        let normHost = SiteSettingsState.normalise(host)
        guard !normHost.isEmpty else { return nil }
        let hasOtherTab = allTabs.contains { other in
            guard other.identity == space.identity, let otherHost = other.url.host() else { return false }
            return SiteSettingsState.normalise(otherHost) == normHost
        }
        return hasOtherTab ? nil : space.identity
    }

    /// Every tab in the space but this one.
    func closeOtherTabs(than tab: Tab) {
        for other in activeSpace.tabs where other !== tab { closeTab(other) }
    }

    /// Every tab after this one in the space's order.
    func closeTabs(below tab: Tab) {
        let space = activeSpace
        guard let index = space.index(of: tab) else { return }
        for other in space.tabs[(index + 1)...] { closeTab(other) }
    }

    /// Closes a collection of tabs in batch.
    func closeTabs(_ tabsToClose: [Tab]) {
        let unlockeds = tabsToClose.filter { !$0.isLocked }
        if unlockeds.count > 1, let first = unlockeds.first,
           let space = space(containing: first),
           !space.isPrivate {
            recordClosedWindow(title: "Window", tabs: unlockeds, in: space)
        }
        for tab in tabsToClose {
            closeTab(tab)
        }
    }

    /// Closes every tab whose address another tab in the space already
    /// shows, keeping the first of each (and the active one when it is
    /// among them). Locked and pinned tabs stay. Returns how many closed.
    @discardableResult
    func closeDuplicateTabs(in space: Space? = nil) -> Int {
        let space = space ?? activeSpace
        var seen: Set<String> = []
        var duplicates: [Tab] = []
        // The active tab is looked at first so it is the one kept.
        let ordered = space.tabs.sorted { a, _ in a.id == space.activeTabID }
        for tab in ordered {
            let key = tab.displayURL.absoluteString
            if seen.contains(key) {
                if !tab.isLocked, !isPinned(tab) { duplicates.append(tab) }
            } else {
                seen.insert(key)
            }
        }
        guard !duplicates.isEmpty else { return 0 }
        closeTabs(duplicates)
        return duplicates.count
    }

    /// The tabs in the space whose address another tab there also shows:
    /// every copy but the first, and the first too, so both are marked.
    func duplicateTabIDs(in space: Space? = nil) -> Set<Tab.ID> {
        let space = space ?? activeSpace
        var byAddress: [String: [Tab.ID]] = [:]
        for tab in space.tabs {
            byAddress[tab.displayURL.absoluteString, default: []].append(tab.id)
        }
        return Set(byAddress.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// How a space's tabs can be put in order.
    enum TabSortOrder: String, CaseIterable {
        case title, domain, lastUsed

        var title: String {
            switch self {
            case .title: return "Title"
            case .domain: return "Domain"
            case .lastUsed: return "Last Used"
            }
        }
    }

    /// Reorders the space's tabs. Stable, so tabs that compare equal keep
    /// their order.
    func sortTabs(by order: TabSortOrder, in space: Space? = nil) {
        let space = space ?? activeSpace
        let indexed = space.tabs.enumerated()
        let sorted = indexed.sorted { a, b in
            let lhs = a.element, rhs = b.element
            switch order {
            case .title:
                let result = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                return result == .orderedSame ? a.offset < b.offset : result == .orderedAscending
            case .domain:
                let left = lhs.displayURL.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
                let right = rhs.displayURL.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
                let result = left.localizedCaseInsensitiveCompare(right)
                return result == .orderedSame ? a.offset < b.offset : result == .orderedAscending
            case .lastUsed:
                return lhs.lastActiveAt == rhs.lastActiveAt ? a.offset < b.offset : lhs.lastActiveAt > rhs.lastActiveAt
            }
        }.map(\.element)
        guard space.replaceTabs(with: sorted) else { return }
        changes.send(.tabs)
        scheduleSave()
    }

    /// Closes all unpinned tabs in the given space.
    func closeAllTabs(in space: Space) {
        let unlockeds = space.tabs.filter { !$0.isLocked }
        if unlockeds.count > 1 && !space.isPrivate {
            recordClosedWindow(title: "\(space.name) Window", tabs: unlockeds, in: space)
        }
        for tab in space.tabs {
            closeTab(tab)
        }
    }

    /// Moves a collection of tabs to another space in batch.
    func moveTabs(_ tabsToMove: [Tab], toSpace space: Space) {
        for tab in tabsToMove {
            move(tab, toSpace: space)
        }
    }

    /// Reloads a collection of tabs in batch.
    func reloadTabs(_ tabsToReload: [Tab]) {
        for tab in tabsToReload {
            tab.reload()
        }
    }

    /// Duplicates a collection of tabs in batch.
    @discardableResult
    func duplicateTabs(_ tabsToDuplicate: [Tab]) -> [Tab] {
        tabsToDuplicate.compactMap { duplicate($0) }
    }

    /// Pins a collection of tabs in batch.
    func pinTabs(_ tabsToPin: [Tab]) {
        for tab in tabsToPin {
            if !isPinned(tab) {
                pin(tab)
            }
        }
    }

    /// Unpins a collection of tabs in batch.
    func unpinTabs(_ tabsToUnpin: [Tab]) {
        for tab in tabsToUnpin {
            if isPinned(tab) {
                unpin(tab)
            }
        }
    }

    /// Takes a tab out of its space and out of the window, tearing its page
    /// down. The half of closing that a move to another space shares.
    private func detach(_ tab: Tab, from space: Space, keepingPage: Bool = false) {
        guard let index = space.index(of: tab) else { return }

        // Closing a pane is first a removal from the split, so the 2 -> 1
        // dissolve and the sibling rescale happen exactly once.
        removeFromSplit(tab)

        let wasActive = space.activeTabID == tab.id
        if !keepingPage { forget(tab) }
        space.remove(tab)

        if wasActive {
            let neighbour = space.tabs.indices.contains(index) ? space.tabs[index]
                : space.tabs.indices.contains(index - 1) ? space.tabs[index - 1]
                : nil
            if let neighbour, neighbour.wasAutoPictureInPicture, neighbour.isInPictureInPicture {
                neighbour.exitPictureInPicture()
            }
            space.setActiveTabID(neighbour?.id)
        }

        if space.id == activeSpaceID {
            changes.send(.tabs)
            if wasActive { changes.send(.activeTab) }
        }
        scheduleSave()
    }

    /// A second tab on the same page, right after the first, in the same
    /// folder, and selected. Made directly rather than through `newTab`, which
    /// may route an address to another space; a duplicate belongs beside its
    /// original by definition.
    @discardableResult
    func duplicate(_ tab: Tab) -> Tab? {
        let space = activeSpace
        guard let index = space.index(of: tab) else { return nil }
        // Keep the user's title, icon and retained URL. A duplicate is a
        // separate tab, so it must not own its original's Favorite or import key.
        var snapshot = tab.snapshot()
        snapshot.pinnedSiteID = nil
        snapshot.importedSourceID = nil
        let copy = Tab(restoring: snapshot, identity: space.identity)
        insert(copy, into: space, at: index + 1, select: true)
        return copy
    }

    /// Same-profile moves keep the page. Crossing profiles rebuilds from the
    /// URL and metadata, without transferring opaque WebKit browsing state.
    func move(_ tab: Tab, toSpace target: Space) {
        guard let source = space(containing: tab),
              source.id != target.id,
              spaces.contains(where: { $0.id == target.id })
        else { return }
        if source.profile === target.profile {
            // A shared Favorite already exists in both layouts.
            guard tab.pinnedSiteID == nil else { return }
            detach(tab, from: source, keepingPage: true)
            tab.setGroupID(nil)
            insert(tab, into: target, at: target.workspaceTabs.count, select: false)
            return
        }
        var snapshot = tab.snapshot()
        snapshot.groupID = nil
        snapshot.pinnedSiteID = nil
        snapshot.interactionState = nil
        let wasFavorite = tab.pinnedSiteID != nil
        detach(tab, from: source)
        if wasFavorite { repairSelections(for: source.profile) }
        let moved = Tab(restoring: snapshot, identity: target.identity)
        insert(moved, into: target, at: target.tabs.count, select: false)
    }

    /// Moves a whole group -- its nested subgroups and every tab filed under any
    /// of them -- to another space, keeping the structure intact. The group's
    /// own "Move to Space" menu, the counterpart of a tab's.
    func move(_ group: TabGroup, toSpace target: Space) {
        guard let source = spaces.first(where: { $0.group(withID: group.id) != nil }),
              source.id != target.id,
              spaces.contains(where: { $0.id == target.id })
        else { return }

        // The group and everything nested under it travel together.
        let moving = [group] + FolderTree.descendants(of: group, in: source.groups)
        let movingIDs = Set(moving.map(\.id))
        // Captured before any detach empties the source's tab list.
        let movingTabs = source.tabs.filter { $0.groupID.map(movingIDs.contains) ?? false }

        // If the moved root's parent stays behind, it becomes a root in the
        // target rather than pointing at a folder that is not there.
        if let parent = group.parentID, !movingIDs.contains(parent) {
            group.parentID = nil
        }

        // Carry the groups over first -- with the non-orphaning removal, so the
        // tabs still filed under them survive the trip -- then the tabs, each
        // rebuilt for the target's identity but keeping the group it belongs to.
        for moved in moving {
            source.detachGroup(moved)
            target.addGroup(moved)
        }
        for tab in movingTabs {
            if source.profile === target.profile {
                detach(tab, from: source, keepingPage: true)
                insert(tab, into: target, at: target.workspaceTabs.count, select: false)
                continue
            }
            var snapshot = tab.snapshot()
            snapshot.pinnedSiteID = nil
            snapshot.interactionState = nil
            detach(tab, from: source)
            let moved = Tab(restoring: snapshot, identity: target.identity)
            insert(moved, into: target, at: target.tabs.count, select: false)
        }

        changes.send(.structure)
        scheduleSave()
    }

    /// Copies the complete subtree beside its original without changing the
    /// selected page or importing the copy again on the next Arc migration.
    @discardableResult
    func duplicateFolder(_ group: TabGroup, iconStore: SpaceIconStore = .shared) throws -> TabGroup? {
        guard !group.isLive, let source = spaces.first(where: { $0.group(withID: group.id) === group }) else { return nil }
        let ids = Set(([group] + FolderTree.descendants(of: group, in: source.groups)).map(\.id))
        let originals = FolderTree.ordered(source.groups).map(\.folder).filter { ids.contains($0.id) }
        let newIDs = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, UUID()) })
        var pictures: [UUID: String] = [:]
        do {
            for folder in originals {
                if let name = folder.iconFileName { pictures[folder.id] = try iconStore.duplicateIcon(named: name) }
            }
        } catch {
            for name in pictures.values { iconStore.remove(named: name) }
            throw error
        }
        let copies = originals.map { folder in
            TabGroup(id: newIDs[folder.id]!, name: folder.name, emoji: folder.emoji,
                tint: folder.tint, appearance: folder.appearance, isCollapsed: folder.isCollapsed,
                parentID: folder === group ? group.parentID.flatMap { ids.contains($0) ? nil : $0 } : folder.parentID.flatMap { newIDs[$0] },
                symbolName: folder.symbolName, iconFileName: pictures[folder.id],
                isLocked: folder.isLocked, sidebarPosition: folder.sidebarPosition,
                badgeIcon: folder.badgeIcon, hasUserChosenIcon: folder.hasUserChosenIcon)
        }
        guard let root = copies.first(where: { $0.id == newIDs[group.id] }) else { return nil }
        let siblings = SidebarOrder.items(groups: source.groups, tabs: source.listedTabs, parentID: group.parentID)
        let following = siblings.firstIndex { $0.id == group.id }.flatMap { index in
            siblings.indices.contains(index + 1) ? siblings[index + 1] : nil
        }
        for copy in copies { source.addGroup(copy) }
        // Live children become regular copies of their current contents, not
        // unregistered live providers polling the same source in the background.
        for tab in FolderContents.tabs(in: group, space: source) {
            var snapshot = tab.snapshot()
            snapshot.groupID = snapshot.groupID.flatMap { newIDs[$0] }
            snapshot.importedSourceID = nil
            snapshot.pinnedSiteID = nil
            snapshot.interactionState = nil
            insert(Tab(restoring: snapshot, identity: source.identity), into: source, at: source.workspaceTabs.count, select: false)
        }
        SidebarOrder.place(.folder(root), before: following, in: siblings, separatesOrdinaryTabs: group.parentID == nil)
        changes.send(.structure)
        scheduleSave()
        return root
    }

    /// Promotes a folder's contents into a Space with the same profile. Existing
    /// tabs keep their live page and nested folders keep their mixed ordering.
    @discardableResult
    func turnFolderIntoSpace(_ group: TabGroup) -> Space? {
        guard !group.isLive, !group.isLocked,
              let source = spaces.first(where: { $0.group(withID: group.id) === group }) else { return nil }
        let contents = SidebarOrder.items(groups: source.groups, tabs: source.listedTabs, parentID: group.id)
        let tabs = FolderContents.tabs(in: group, space: source)
        let selected = tabs.first { $0.id == source.activeTabID } ?? tabs.first
        let target = Space(name: Space.clampName(group.name), identity: source.identity, profile: source.profile,
                           theme: source.theme, border: source.border, look: source.look)
        target.icon = group.icon.spaceIcon
        spaces.append(target)
        move(group, toSpace: target)
        for (index, item) in contents.enumerated() {
            switch item {
            case .folder(let child): child.parentID = nil
            case .tab(let tab): tab.setGroupID(nil); tab.setKeepsInSidebar(true)
            }
            item.position = index
        }
        // Detaching rather than deleting transfers ownership of a custom icon
        // to the Space instead of removing its file.
        target.detachGroup(group)
        if let selected { target.setActiveTabID(selected.id) }
        changes.send(.structure)
        selectSpace(target)
        if target.workspaceTabs.isEmpty { newTab() }
        scheduleSave()
        return target
    }

    /// A local copy of a Space's sidebar in a folder. The source stays intact;
    /// Favorites remain profile-owned and are not copied into the folder.
    /// Destination tabs start unloaded in the destination's browsing identity.
    @discardableResult
    func exportSpace(_ source: Space, intoFolderIn target: Space, iconStore: SpaceIconStore = .shared) throws -> TabGroup? {
        guard source !== target, spaces.contains(where: { $0 === source }),
              spaces.contains(where: { $0 === target }) else { return nil }
        let ordered = FolderTree.ordered(source.groups)
        let ids = Dictionary(uniqueKeysWithValues: ordered.map { ($0.folder.id, UUID()) })
        let root = TabGroup(name: source.name, tint: source.color)
        var pictures: [UUID: String] = [:]
        // Prepare independent image files before changing the target. An icon
        // failure must not leave a partial folder tree or share file ownership.
        do {
            if let name = source.icon.customFileName { pictures[root.id] = try iconStore.duplicateIcon(named: name) }
            for entry in ordered {
                if let name = entry.folder.iconFileName { pictures[entry.folder.id] = try iconStore.duplicateIcon(named: name) }
            }
        } catch {
            for name in pictures.values { iconStore.remove(named: name) }
            throw error
        }
        switch source.icon {
        case .automatic: break
        case .emoji(let value): root.setIcon(.emoji(value))
        case .symbol(let value): root.setIcon(.symbol(value))
        case .custom: if let file = pictures[root.id] { root.setIcon(.custom(file)) }
        }
        let roots = SidebarOrder.items(groups: source.groups, tabs: source.listedTabs)
        let rootPositions = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($0.element.id, $0.offset) })
        let rootIDs = Set(ordered.filter { $0.depth == 0 }.map { $0.folder.id })
        let siblings = SidebarOrder.items(groups: target.groups, tabs: target.listedTabs)
        target.addGroup(root)
        for entry in ordered {
            let folder = entry.folder
            // Existing deep trees remain intact. The nesting cap controls new
            // folder creation and drops, not visibility of imported contents.
            let parent = rootIDs.contains(folder.id) ? root.id : (folder.parentID.flatMap { ids[$0] } ?? root.id)
            target.addGroup(TabGroup(id: ids[folder.id]!, name: folder.name, emoji: folder.emoji,
                tint: folder.tint, appearance: folder.appearance, isCollapsed: folder.isCollapsed,
                parentID: parent, symbolName: folder.symbolName, iconFileName: pictures[folder.id],
                isLocked: folder.isLocked, sidebarPosition: rootPositions[folder.id] ?? folder.sidebarPosition,
                badgeIcon: folder.badgeIcon, hasUserChosenIcon: folder.hasUserChosenIcon))
        }
        for tab in source.listedTabs where !tab.isSidebarPlaceholder {
            var snapshot = tab.snapshot()
            snapshot.groupID = tab.groupID.flatMap { ids[$0] } ?? root.id
            if snapshot.groupID == root.id { snapshot.sidebarPosition = rootPositions[tab.id] }
            snapshot.importedSourceID = nil
            snapshot.pinnedSiteID = nil
            snapshot.interactionState = nil
            insert(Tab(restoring: snapshot, identity: target.identity), into: target, at: target.workspaceTabs.count, select: false)
        }
        SidebarOrder.place(.folder(root), before: nil, in: siblings)
        changes.send(.structure)
        scheduleSave()
        return root
    }

    // MARK: - Closed tabs and windows

    /// A closed tab, kept so it can come back: what it held and where it was.
    struct ClosedTab: Identifiable, Sendable {
        let id: UUID
        let snapshot: SessionSnapshot.Tab
        let spaceID: Space.ID
        let closedAt: Date

        init(id: UUID = UUID(), snapshot: SessionSnapshot.Tab, spaceID: Space.ID, closedAt: Date = Date()) {
            self.id = id
            self.snapshot = snapshot
            self.spaceID = spaceID
            self.closedAt = closedAt
        }

        var title: String {
            if let custom = snapshot.customName, !custom.isEmpty { return custom }
            if let title = snapshot.title, !title.isEmpty { return title }
            if let host = snapshot.url.host(), !host.isEmpty { return host }
            return snapshot.url.absoluteString
        }

        var url: URL { snapshot.url }
    }

    /// A closed window snapshot, kept so an entire closed window or batch of tabs can be restored.
    struct ClosedWindow: Identifiable, Sendable {
        let id: UUID
        let title: String
        let spaceID: Space.ID
        let tabs: [SessionSnapshot.Tab]
        let closedAt: Date

        init(
            id: UUID = UUID(),
            title: String = "Window",
            spaceID: Space.ID,
            tabs: [SessionSnapshot.Tab],
            closedAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.spaceID = spaceID
            self.tabs = tabs
            self.closedAt = closedAt
        }

        var tabCount: Int { tabs.count }

        var summaryTitle: String {
            let countStr = "\(tabs.count) tab\(tabs.count == 1 ? "" : "s")"
            let names = tabs.prefix(3).compactMap { tab -> String? in
                if let custom = tab.customName, !custom.isEmpty { return custom }
                if let title = tab.title, !title.isEmpty { return title }
                return tab.url.host() ?? tab.url.absoluteString
            }
            if names.isEmpty {
                return "\(title) (\(countStr))"
            }
            return "\(title) (\(countStr)) \u{2014} " + names.joined(separator: ", ")
        }
    }

    /// Most recent last. In memory only: the list is gone at quit, which is
    /// what makes it safe to keep at all.
    private(set) var closedTabs: [ClosedTab] = []
    private(set) var closedWindows: [ClosedWindow] = []
    static let closedTabLimit = 25
    static let closedWindowLimit = 15

    var canReopenClosedTab: Bool { !closedTabs.isEmpty || !closedWindows.isEmpty }

    /// Returns recently closed tabs in most-recent-first order for display in menus.
    var recentClosedTabs: [ClosedTab] {
        Array(closedTabs.reversed())
    }

    /// Returns recently closed windows in most-recent-first order for display in menus.
    var recentClosedWindows: [ClosedWindow] {
        Array(closedWindows.reversed())
    }

    /// Photographs a tab before it goes. A private space keeps nothing, not
    /// even this: reopening would bring back a page whose logins are gone,
    /// and remembering it contradicts what "private" promised.
    private func remember(closing tab: Tab, in space: Space) {
        guard !space.isPrivate else { return }
        closedTabs.append(ClosedTab(snapshot: tab.snapshot(), spaceID: space.id))
        if closedTabs.count > Self.closedTabLimit {
            closedTabs.removeFirst(closedTabs.count - Self.closedTabLimit)
        }
    }

    /// Records a batch of tabs or an entire window being closed.
    func recordClosedWindow(title: String = "Window", tabs: [Tab], in space: Space) {
        guard !space.isPrivate, !tabs.isEmpty else { return }
        let snapshots = tabs.map { $0.snapshot() }
        closedWindows.append(ClosedWindow(title: title, spaceID: space.id, tabs: snapshots))
        if closedWindows.count > Self.closedWindowLimit {
            closedWindows.removeFirst(closedWindows.count - Self.closedWindowLimit)
        }
    }

    /// Records a closed tab from a Little Arc window.
    func recordClosedLittleArcTab(url: URL, title: String?, spaceID: Space.ID) {
        guard let space = spaces.first(where: { $0.id == spaceID }), !space.isPrivate else { return }
        var snapshot = SessionSnapshot.Tab(url: url)
        snapshot.title = title
        closedTabs.append(ClosedTab(snapshot: snapshot, spaceID: spaceID))
        if closedTabs.count > Self.closedTabLimit {
            closedTabs.removeFirst(closedTabs.count - Self.closedTabLimit)
        }
    }

    /// Brings the most recently closed tab back into the space it was closed
    /// from, or the active space if that one has gone, and selects it.
    @discardableResult
    func reopenClosedTab() -> Tab? {
        guard !closedTabs.isEmpty else {
            if !closedWindows.isEmpty {
                return reopenClosedWindow().last
            }
            return nil
        }
        return restore(closedTab: closedTabs.removeLast())
    }

    /// Reopens a specific closed tab by ID.
    @discardableResult
    func reopenClosedTab(id: UUID) -> Tab? {
        guard let index = closedTabs.firstIndex(where: { $0.id == id }) else { return nil }
        return restore(closedTab: closedTabs.remove(at: index))
    }

    /// Reopens a specific closed tab by index in the closedTabs array.
    @discardableResult
    func reopenClosedTab(at index: Int) -> Tab? {
        guard index >= 0 && index < closedTabs.count else { return nil }
        return restore(closedTab: closedTabs.remove(at: index))
    }

    private func restore(closedTab closed: ClosedTab) -> Tab {
        let space = spaces.first { $0.id == closed.spaceID } ?? activeSpace
        var snapshot = closed.snapshot
        // Its folder may have been deleted in the meantime; a tab pointing at
        // a group that no longer exists would be invisible in the sidebar.
        if let groupID = snapshot.groupID, space.group(withID: groupID) == nil {
            snapshot.groupID = nil
        }
        snapshot.pinnedSiteID = nil
        let tab = Tab(restoring: snapshot, identity: space.identity)
        if space.id != activeSpaceID { selectSpace(space) }
        insert(tab, into: space, at: space.tabs.count, select: true)
        return tab
    }

    /// Reopens the most recently closed window, restoring all its tabs.
    @discardableResult
    func reopenClosedWindow() -> [Tab] {
        guard let closed = closedWindows.popLast() else { return [] }
        return restore(closedWindow: closed)
    }

    /// Reopens a specific closed window by ID.
    @discardableResult
    func reopenClosedWindow(id: UUID) -> [Tab] {
        guard let index = closedWindows.firstIndex(where: { $0.id == id }) else { return [] }
        return restore(closedWindow: closedWindows.remove(at: index))
    }

    /// Reopens a specific closed window by index in closedWindows array.
    @discardableResult
    func reopenClosedWindow(at index: Int) -> [Tab] {
        guard index >= 0 && index < closedWindows.count else { return [] }
        return restore(closedWindow: closedWindows.remove(at: index))
    }

    private func restore(closedWindow closed: ClosedWindow) -> [Tab] {
        let space = spaces.first { $0.id == closed.spaceID } ?? activeSpace
        if space.id != activeSpaceID { selectSpace(space) }
        var restoredTabs: [Tab] = []
        for var snapshot in closed.tabs {
            if let groupID = snapshot.groupID, space.group(withID: groupID) == nil {
                snapshot.groupID = nil
            }
            snapshot.pinnedSiteID = nil
            let tab = Tab(restoring: snapshot, identity: space.identity)
            insert(tab, into: space, at: space.tabs.count, select: false)
            restoredTabs.append(tab)
        }
        if let lastTab = restoredTabs.last {
            selectTab(lastTab)
        }
        return restoredTabs
    }

    /// Reopens all recently closed tabs and windows.
    @discardableResult
    func reopenAllClosedTabs() -> [Tab] {
        var restored: [Tab] = []
        while !closedWindows.isEmpty {
            restored.append(contentsOf: reopenClosedWindow())
        }
        while !closedTabs.isEmpty {
            if let tab = reopenClosedTab() {
                restored.append(tab)
            }
        }
        return restored
    }

    /// Clears both closed tabs and closed windows history.
    func clearRecentlyClosed() {
        closedTabs.removeAll()
        closedWindows.removeAll()
    }

    // MARK: - Archived tabs

    /// A tab that left the sidebar on its own, and the space it left from.
    ///
    /// Saved, unlike `closedTabs`. Closing is something the user did and can
    /// remember doing; archiving happens while they are not looking, so a list
    /// that emptied at quit would mean tabs disappearing with nothing to point
    /// at afterwards. The identifier is the record's own: the `Tab` is gone,
    /// and what is left is a photograph of it.
    struct ArchivedTab: Identifiable {
        let id: UUID
        var snapshot: SessionSnapshot.Tab
        var spaceID: Space.ID
        var archivedAt: Date

        init(id: UUID = UUID(), snapshot: SessionSnapshot.Tab, spaceID: Space.ID, archivedAt: Date) {
            self.id = id
            self.snapshot = snapshot
            self.spaceID = spaceID
            self.archivedAt = archivedAt
        }

        /// What to call it in the archive list, preferring the name the user
        /// gave it over the one the page did.
        var title: String {
            if let custom = snapshot.customName, !custom.isEmpty { return custom }
            if let page = snapshot.title, !page.isEmpty { return page }
            return snapshot.url.host() ?? snapshot.url.absoluteString
        }
    }

    /// Oldest first, every space's together. Each record names the space it
    /// left, and that is what the archive is filed by: a space's archive is the
    /// records that carry its id, and nothing in one space's archive is ever
    /// shown in, restored into, or cleared by another's. Reach it through
    /// `archivedTabs(in:)` rather than reading this array -- it is one store
    /// because it is one file, not because it is one list.
    private(set) var archivedTabs: [ArchivedTab] = []

    /// Bounded, because an archive that grows without limit is a session file
    /// that grows without limit; the cap is generous enough that reaching it
    /// means the setting is doing its job.
    ///
    /// Counted per space rather than across all of them. A shared ceiling
    /// would mean one busy space's sweep silently evicting the oldest records
    /// out of a quiet space's archive -- the space's own drawer emptying
    /// because of something that happened in a space the user was not even in.
    private static let archiveLimit = 500

    /// One space's archive, most recently archived first -- the order someone
    /// looking for "the thing that just vanished" reads in.
    func archivedTabs(in space: Space) -> [ArchivedTab] {
        archivedTabs
            .filter { $0.spaceID == space.id }
            .sorted { $0.archivedAt > $1.archivedAt }
    }

    /// Takes tabs out of the sidebar and into the archive, whole: the saved
    /// interaction state goes with them, so restoring one brings back its
    /// scroll position and its back-forward list rather than just an address.
    func archive(_ tabs: [Tab]) {
        var archived = 0
        // Collected as we go: `detach` takes the tab out of its space, so by
        // the end of the loop there is no way left to ask which space a tab
        // came from.
        var touched: Set<Space.ID> = []
        for tab in tabs {
            guard let space = space(containing: tab) else { continue }
            // A private space keeps nothing that outlives it -- not even this.
            // Archiving there would write to disk exactly what "private"
            // promised would never be written, so a private tab is left alone.
            guard !space.isPrivate else { continue }
            archivedTabs.append(
                ArchivedTab(snapshot: tab.snapshot(), spaceID: space.id, archivedAt: .now)
            )
            if let groupID = tab.groupID {
                liveFolders.tabWasRemoved(tab.id, fromFolder: groupID)
            }
            detach(tab, from: space)
            touched.insert(space.id)
            archived += 1
        }
        guard archived > 0 else { return }
        trimArchives(of: touched)
        Metrics.log("archive count=\(tabs.count) total=\(archivedTabs.count)")
        changes.send(.structure)
        scheduleSave()
        showToast?(.archived(count: archived, undo: { [weak self] in self?.undoArchive(archived) }))
    }

    /// Puts back everything the last sweep took, for the toast's Undo.
    ///
    /// Archiving is the only thing in the browser that removes a row without
    /// the user touching anything, so it is the one thing that has to offer the
    /// undo up front rather than leave it to be found later in a window.
    private func undoArchive(_ count: Int) {
        // Copied out first: `restoreArchived` removes from the same array.
        let restorable = Array(archivedTabs.suffix(count))
        for record in restorable { restoreArchived(record) }
    }

    /// Brings one back, into the space it left from or the active space if that
    /// space has gone. It returns awake and selected: restoring a tab is an act
    /// of wanting to read it.
    @discardableResult
    func restoreArchived(_ archived: ArchivedTab) -> Tab? {
        guard let index = archivedTabs.firstIndex(where: { $0.id == archived.id }) else { return nil }
        let record = archivedTabs.remove(at: index)
        let space = spaces.first { $0.id == record.spaceID } ?? activeSpace
        let tab = revive(record, into: space)
        if space.id != activeSpaceID { selectSpace(space) }
        insert(tab, into: space, at: space.tabs.count, select: true)
        scheduleSave()
        return tab
    }

    /// Puts a space's whole archive back where it came from, in the order it
    /// left: the sidebar ends up reading the way it did before the sweep, not
    /// reversed.
    ///
    /// The counterpart to Clear. Clear is the answer to "I am never going to
    /// want any of these"; this is the answer to the opposite, and without it
    /// the only way back from an archive of thirty tabs is thirty clicks.
    ///
    /// The rows go in without announcing themselves one at a time -- a `.tabs`
    /// per tab would rebuild and re-animate the sidebar's list once for every
    /// tab restored, which on a full archive is the difference between a list
    /// appearing and a list flickering into place.
    @discardableResult
    func restoreAllArchived(in space: Space) -> [Tab] {
        let records = archivedTabs
            .filter { $0.spaceID == space.id }
            .sorted { $0.archivedAt < $1.archivedAt }
        guard !records.isEmpty else { return [] }
        archivedTabs.removeAll { $0.spaceID == space.id }

        let restored = records.map { record -> Tab in
            let tab = revive(record, into: space)
            adopt(tab)
            space.insert(tab, at: space.tabs.count)
            return tab
        }
        // The one archived most recently ends up selected: it is the one a
        // user who has just emptied the archive went looking for.
        if space.activeTabID == nil, let last = restored.last {
            space.setActiveTabID(last.id)
        }
        if space.id != activeSpaceID { selectSpace(space) }
        if let last = restored.last { selectTab(last) }

        changes.send(.structure)
        changes.send(.tabs)
        changes.send(.activeTab)
        scheduleSave()
        return restored
    }

    /// One archived record as a tab again, ready to be put into `space`.
    private func revive(_ record: ArchivedTab, into space: Space) -> Tab {
        var snapshot = record.snapshot
        // Its folder may have been deleted while it sat in the archive; a tab
        // pointing at a group that no longer exists would be invisible.
        if let groupID = snapshot.groupID, space.group(withID: groupID) == nil {
            snapshot.groupID = nil
        }
        snapshot.pinnedSiteID = nil
        // A fresh clock. Restoring a tab and having the sweep archive it again
        // on the next pass -- because its saved `lastActiveAt` is still days old
        // -- would be the single most infuriating bug this feature could have.
        snapshot.lastActiveAt = .now
        return Tab(restoring: snapshot, identity: space.identity)
    }

    /// Drops one from the archive without bringing it back.
    func forgetArchived(_ archived: ArchivedTab) {
        guard let index = archivedTabs.firstIndex(where: { $0.id == archived.id }) else { return }
        archivedTabs.remove(at: index)
        changes.send(.structure)
        scheduleSave()
    }

    /// Holds each named space's archive to `archiveLimit`, oldest out first.
    ///
    /// Only the spaces that just archived something are considered: a space
    /// nobody touched cannot have grown, and walking every space's records on
    /// every sweep to prove that is work for nothing.
    private func trimArchives(of spaceIDs: Set<Space.ID>) {
        for spaceID in spaceIDs {
            let theirs = archivedTabs.filter { $0.spaceID == spaceID && $0.snapshot.importedSourceID == nil }
            guard theirs.count > Self.archiveLimit else { continue }
            let dropped = Set(theirs.prefix(theirs.count - Self.archiveLimit).map(\.id))
            archivedTabs.removeAll { dropped.contains($0.id) }
        }
    }

    /// Empties one space's archive and leaves every other space's alone.
    ///
    /// The archive is filed by space and shown by space, so the Clear button
    /// under a space's list clears the list that is in front of the user. One
    /// change rather than one per row: the sidebar has no reason to rebuild its
    /// list once per archived tab.
    func clearArchive(in space: Space) {
        let kept = archivedTabs.filter { $0.spaceID != space.id }
        guard kept.count != archivedTabs.count else { return }
        archivedTabs = kept
        changes.send(.structure)
        scheduleSave()
    }

    /// Empties every space's archive at once. Nothing in the UI reaches this --
    /// Clear is per space -- but a wipe of the whole store is what resetting
    /// the browser means, and having it in one place keeps that honest.
    func clearArchive() {
        guard !archivedTabs.isEmpty else { return }
        archivedTabs.removeAll()
        changes.send(.structure)
        scheduleSave()
    }

    func selectTab(_ tab: Tab) {
        let space = activeSpace
        guard space.index(of: tab) != nil, space.activeTabID != tab.id else { return }

        // If the space has an active split with a sticky pane, replace the unsticky pane
        // so the user can browse tabs while keeping the stuck pane pinned on screen.
        if let layout = space.splits.layout(containing: space.activeTabID),
           let stickyID = layout.tabIDs.first(where: space.splits.stickyTabIDs.contains),
           space.splits.layout(containing: tab.id) == nil,
           tab.id != stickyID,
           !layout.contains(tab.id) {
            let toReplace = layout.tabIDs.first(where: { $0 == space.activeTabID && $0 != stickyID })
                ?? layout.tabIDs.first(where: { $0 != stickyID })
            if let toReplace {
                recordSplitUndoState()
                space.splits.replace(toReplace, with: tab.id)
            }
        }

        if settings.autoPictureInPicture {
            if let prevTab = space.activeTab, prevTab.hasPlayingVideo, !prevTab.isInPictureInPicture {
                prevTab.requestPictureInPicture(autoTriggered: true)
            }
            if tab.wasAutoPictureInPicture && tab.isInPictureInPicture {
                tab.exitPictureInPicture()
            }
        }
        space.setActiveTabID(tab.id)
        space.splits.focus(tab.id)
        changes.send(.activeTab)
        scheduleSave()
    }

    /// Brings a tab to the front wherever it lives, changing Space if it is
    /// not in the current one. A web notification's click arrives with nothing
    /// but a tab identifier, and the tab it names may be anywhere -- or gone,
    /// which is why this answers rather than assuming.
    @discardableResult
    func revealTab(id: UUID) -> Tab? {
        if let tab = activeSpace.tabs.first(where: { $0.id == id }) {
            selectTab(tab)
            return tab
        }
        guard let space = spaces.first(where: { $0.tabs.contains { $0.id == id } }),
              let tab = space.tabs.first(where: { $0.id == id }) else { return nil }
        if space.id != activeSpace.id { selectSpace(space) }
        selectTab(tab)
        return tab
    }

    /// 1-based, to match the Cmd-1 ... Cmd-9 menu items. Cmd-9 is the last tab.
    /// Tab `number` as the sidebar counts them, so Cmd-3 is the third row
    /// the user can see; a pinned site's tab is not listed and not counted.
    /// Past the end, nine and above mean the last tab.
    func selectTab(number: Int) {
        let tabs = activeSpace.sidebarVisibleTabs
        guard !tabs.isEmpty else { return }
        let index = tabs.indices.contains(number - 1) ? number - 1
            : number >= 9 ? tabs.count - 1
            : -1
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index])
    }

    func selectTab(offsetBy offset: Int) {
        let tabs = activeSpace.tabs
        guard tabs.count > 1,
              let current = activeSpace.activeTabID,
              let index = tabs.firstIndex(where: { $0.id == current }) else { return }
        let wrapped = (index + offset % tabs.count + tabs.count) % tabs.count
        selectTab(tabs[wrapped])
    }

    func moveTab(from source: Int, to destination: Int) {
        activeSpace.move(from: source, to: destination)
        changes.send(.tabs)
        scheduleSave()
    }

    /// Dragging a compact split row files and positions all of its pages as
    /// one unit. The layout and remembered pane stay attached to that unit.
    @discardableResult
    func moveSidebarTab(_ tab: Tab, to index: Int, group: TabGroup?, before target: SidebarItem?, retained: Bool) -> Bool {
        let space = activeSpace
        guard space.tabs.contains(where: { $0 === tab }),
              group == nil || space.groups.contains(where: { $0 === group }) else { return false }
        let ids = space.splits.layout(containing:tab.id)?.tabIDs ?? [tab.id]
        let members = ids.compactMap { id in space.tabs.first { $0.id == id } }
        guard members.count == ids.count, members.allSatisfy({ $0.pinnedSiteID == nil }) else { return false }
        if let target {
            if ids.contains(target.id) { return true }
            switch target {
            case .folder(let folder):
                guard space.groups.contains(where: { $0 === folder }), folder.parentID == group?.id else { return false }
            case .tab(let other):
                guard space.tabs.contains(where: { $0 === other }), other.groupID == group?.id else { return false }
            }
        }
        let moving = Set(ids)
        let boundary = min(max(0,index),space.tabs.count)
        let insertion = space.tabs.prefix(boundary).filter { !moving.contains($0.id) }.count
        var ordered = space.tabs.filter { !moving.contains($0.id) }
        ordered.insert(contentsOf:members,at:insertion)
        guard space.replaceTabs(with:ordered) else { return false }
        for member in members {
            member.setGroupID(group?.id)
            if group == nil { member.setKeepsInSidebar(retained) }
        }
        for member in members {
            SidebarOrder.place(.tab(member),before:target,
                in:SidebarOrder.items(groups:space.groups,tabs:space.listedTabs,parentID:group?.id),
                separatesOrdinaryTabs:group == nil)
        }
        changes.send(.structure)
        scheduleSave()
        return true
    }

    /// Reorders a top-level group, so dragging a group's header in the sidebar
    /// moves it. `before` is the group it should sit ahead of, or nil to send
    /// it past the last one.
    func moveGroup(_ group: TabGroup, before other: TabGroup?) {
        guard activeSpace.groups.contains(where: { $0 === group }), other?.id != group.id else { return }
        guard other == nil || other?.parentID == group.parentID else { return }
        activeSpace.moveGroup(group, before: other)
        SidebarOrder.place(.folder(group), before: other.map(SidebarItem.folder),
                           in: SidebarOrder.items(groups: activeSpace.groups, tabs: activeSpace.listedTabs, parentID: group.parentID),
                           separatesOrdinaryTabs: group.parentID == nil)
        changes.send(.structure)
        scheduleSave()
    }

    func positionSidebarItem(_ item: SidebarItem, before target: SidebarItem?, retained: Bool? = nil) {
        guard target?.id != item.id else { return }
        let parentID: UUID?
        switch item {
        case .folder(let folder):
            guard activeSpace.groups.contains(where: { $0 === folder }) else { return }
            parentID = folder.parentID
        case .tab(let tab):
            guard activeSpace.tabs.contains(where: { $0 === tab }), tab.pinnedSiteID == nil else { return }
            parentID = tab.groupID
            if parentID == nil, let retained { tab.setKeepsInSidebar(retained) }
        }
        if let target {
            let targetParent: UUID?
            switch target { case .folder(let folder): targetParent = folder.parentID; case .tab(let tab): targetParent = tab.groupID }
            guard parentID == targetParent else { return }
        }
        SidebarOrder.place(item, before: target,
                           in: SidebarOrder.items(groups: activeSpace.groups, tabs: activeSpace.listedTabs, parentID: parentID),
                           separatesOrdinaryTabs: parentID == nil)
        changes.send(.structure)
        scheduleSave()
    }

    // MARK: - Tab groups

    /// A folder whose contents a provider maintains: a feed, an account's
    /// pull requests. Named and iconed by the provider, so the user is not
    /// asked to name something they have not seen yet.
    @discardableResult
    func createLiveGroup(source: LiveFolderSource) -> TabGroup {
        let space = activeSpace
        let metadata = LiveFolderManager.metadata(for: source)
        let group = TabGroup(
            name: metadata.name,
            tint: space.color,
            symbolName: metadata.symbolName,
            isLive: true
        )
        space.addGroup(group)
        liveFolders.add(folderID: group.id, source: source)
        changes.send(.structure)
        scheduleSave()
        return group
    }

    @discardableResult
    func createGroup(named name: String, emoji: String? = nil, containing tabs: [Tab] = [], parent: TabGroup? = nil) -> TabGroup {
        let space = activeSpace
        let group = TabGroup(name: name, emoji: emoji, tint: space.color)
        if let parent, space.group(withID: parent.id) === parent, !parent.isLive {
            group.parentID = parent.id
            parent.isCollapsed = false
        }
        space.addGroup(group)
        for tab in tabs where space.index(of: tab) != nil {
            tab.setGroupID(group.id)
        }
        changes.send(.structure)
        scheduleSave()
        return group
    }

    func rename(_ group: TabGroup, to name: String, emoji: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        group.name = trimmed
        if let emoji { group.emoji = emoji.isEmpty ? nil : emoji }
        changes.send(.structure)
        scheduleSave()
    }

    func toggleCollapsed(_ group: TabGroup) {
        group.isCollapsed.toggle()
        changes.send(.structure)
        scheduleSave()
    }

    /// Opening a folder changes the sidebar, keeping its Space's selected page.
    /// Validate ownership before selecting anything: a stale command may name a
    /// folder that has since been deleted or moved to another Space.
    @discardableResult
    func openFolder(_ group: TabGroup, in space: Space) -> Bool {
        guard spaces.contains(where: { $0 === space }), space.group(withID:group.id) === group else { return false }
        selectSpace(space)
        FolderTree.revealAncestors(of:group,in:space.groups)
        group.isCollapsed = false
        if space.look.pinnedSectionCollapsed {
            var look = space.look
            look.pinnedSectionCollapsed = false
            setLook(look,for:space)
        }
        changes.send(.structure)
        scheduleSave()
        return true
    }

    func preferredFolderCommand(for query: String, profile: BrowserProfile) -> UUID? {
        let history = profile.identity.isPrivate ? privateFolderCommands[profile.id] : profile.preferences.folderCommandHistory
        return history?.preferredFolder(for:query)
    }

    func rememberFolderCommand(_ group: TabGroup, in space: Space, query: String, profile: BrowserProfile) {
        guard profiles.contains(where: { $0 === profile }), spaces.contains(where: { $0 === space }),
              space.group(withID:group.id) === group,
              profile.identity.isPrivate == space.isPrivate,
              !profile.identity.isPrivate || space.profile === profile else { return }
        var history = (profile.identity.isPrivate ? privateFolderCommands[profile.id] : profile.preferences.folderCommandHistory)
            ?? FolderCommandHistory()
        history.record(group.id,for:query)
        guard history.count > 0 else { return }
        if profile.identity.isPrivate { privateFolderCommands[profile.id] = history }
        else { profile.preferences.folderCommandHistory = history; scheduleSave() }
    }

    @discardableResult
    func enrichArcFolderCommands(_ choices: [FolderCommandHistory.ImportedChoice], for identity: Space.Identity, sourceID: String) -> Int {
        guard !identity.isPrivate, !sourceID.isEmpty, sourceID.count <= 512,
              let profile = profiles.first(where: { $0.identity == identity }),
              !(profile.preferences.arcFolderCommandSources ?? []).contains(sourceID) else { return 0 }
        var added = 0
        // An explicit empty history records a previous Clear History action.
        if profile.preferences.folderCommandHistory?.count != 0 {
            let folders = Set(spaces.filter { !$0.isPrivate }.flatMap { $0.groups.map(\.id) })
            var history = profile.preferences.folderCommandHistory ?? FolderCommandHistory()
            added = history.importChoices(choices.filter { folders.contains($0.folderID) })
            if added > 0 { profile.preferences.folderCommandHistory = history }
        }
        var sources = profile.preferences.arcFolderCommandSources ?? []
        sources.insert(sourceID)
        profile.preferences.arcFolderCommandSources = sources
        scheduleSave()
        return added
    }

    /// Puts an emoji, a symbol or a picture on a folder -- or takes it off.
    ///
    /// The same three choices a space has, from the same menu and out of the
    /// same store, because they are the same feature: the only difference is
    /// what a folder falls back to when it wears nothing, which is its plate.
    func setIcon(_ icon: FolderIcon, for group: TabGroup) {
        guard group.icon != icon else { return }
        // The picture it was wearing goes as it is replaced. These files are
        // owned by the icon that names them and referred to by nothing else.
        if let old = group.icon.customFileName, old != icon.customFileName {
            SpaceIconStore.shared.remove(named: old)
        }
        group.setIcon(icon)
        changes.send(.structure)
        scheduleSave()
    }

    /// Repaints the plate behind a group: its fill, gradient and raised rim.
    func setAppearance(_ appearance: TabGroupAppearance, for group: TabGroup) {
        guard group.appearance != appearance else { return }
        group.appearance = appearance
        changes.send(.structure)
        scheduleSave()
    }

    /// Deleting a group frees its tabs rather than closing them.
    /// Removes a group. Its tabs move to the main list by default (they are
    /// only ungrouped); with `closingTabs` they are closed along with the group.
    @discardableResult
    func removeGroup(_ group: TabGroup, closingTabs: Bool = false) -> Bool {
        guard !group.isLocked else { return false }
        if closingTabs {
            for tab in activeSpace.tabs.filter({ $0.groupID == group.id }) {
                closeTab(tab)
            }
        }
        // Its picture goes with it, for the same reason a deleted space's
        // does: the file is the icon's, and the icon is going.
        if let fileName = group.icon.customFileName {
            SpaceIconStore.shared.remove(named: fileName)
        }
        activeSpace.removeGroup(group)
        changes.send(.structure)
        scheduleSave()
        return true
    }

    func setLocked(_ locked: Bool, for group: TabGroup) {
        guard locked != group.isLocked else { return }
        group.isLocked = locked
        changes.send(.structure)
        scheduleSave()
    }

    func move(_ tab: Tab, to group: TabGroup?) {
        let space = activeSpace
        guard space.index(of: tab) != nil else { return }
        guard group == nil || space.group(withID: group!.id) != nil else { return }
        tab.setGroupID(group?.id)
        changes.send(.structure)
        scheduleSave()
    }

    // MARK: - Pinned sites

    func pinActiveTab() {
        guard let tab = activeTab else { return }
        pin(tab)
    }

    /// Whether this tab, or its page, is already a tile.
    /// Whether a provider maintains this tab's folder. Such a tab is never
    /// archived: the folder would offer it again on its next poll.
    func isInLiveFolder(_ tab: Tab) -> Bool {
        guard let groupID = tab.groupID else { return false }
        return spaces.contains { $0.group(withID: groupID)?.isLive == true }
    }

    func isPinned(_ tab: Tab) -> Bool {
        tab.pinnedSiteID != nil || activeSpace.pinnedSites.contains { $0.matches(tab.url) }
    }

    /// Turns a tab into a tile. The tab becomes the tile's own, so it leaves
    /// the list rather than showing the same site twice.
    func pin(_ tab: Tab) {
        let space = activeSpace
        guard space.index(of: tab) != nil, !isPinned(tab), space.pinnedSites.count < 12 else { return }
        let site = PinnedSite(url: tab.url, title: tab.displayTitle)
        space.addPinnedSite(site)
        tab.setPinnedSiteID(site.id)
        space.promoteFavorite(tab)
        changes.send(.structure)
        scheduleSave()
    }

    /// Unpins a tab if it was pinned as a tile shortcut.
    func unpin(_ tab: Tab) {
        if let site = activeSpace.pinnedSites.first(where: { $0.id == tab.pinnedSiteID || $0.matches(tab.url) }) {
            removePinnedSite(site)
        }
    }

    func removePinnedSite(_ site: PinnedSite) {
        // The tab outlives the shortcut and rejoins the list, rather than
        // disappearing with a tile the user only meant to unpin.
        if let tab = activeSpace.tab(forPin: site.id) {
            activeSpace.profile.removeFavorite(tab)
            tab.setPinnedSiteID(nil)
            tab.setGroupID(nil)
            activeSpace.insert(tab, at: activeSpace.workspaceTabs.count)
        }
        activeSpace.removePinnedSite(site)
        repairSelections(for: activeSpace.profile)
        changes.send(.structure)
        scheduleSave()
    }

    func movePinnedSite(from source: Int, to destination: Int) {
        activeSpace.movePinnedSite(from: source, to: destination)
        changes.send(.structure)
        scheduleSave()
    }

    /// Opening a pin reuses a tab already on that site rather than piling up
    /// near-duplicates, which is the whole reason a pin is not a tab.
    func openPinnedSite(_ site: PinnedSite) {
        let space = activeSpace
        guard space.pinnedSites.contains(where: { $0.id == site.id }) else { return }
        if let existing = space.tab(forPin: site.id) {
            selectTab(existing)
            return
        }
        // An existing tab already on that site is adopted rather than
        // duplicated -- restoring a session, or pinning the page you are on.
        if let onSite = space.tabs.first(where: { $0.pinnedSiteID == nil && site.matches($0.url) }) {
            onSite.setPinnedSiteID(site.id)
            space.promoteFavorite(onSite)
            selectTab(onSite)
            changes.send(.structure)
            scheduleSave()
            return
        }
        let tab = Tab(url: site.url, identity: space.identity)
        insert(tab, into: space, at: space.workspaceTabs.count, select: true)
        tab.setPinnedSiteID(site.id)
        space.promoteFavorite(tab)
        changes.send(.structure)
        scheduleSave()
    }

    // MARK: - Suspension

    var allTabs: [Tab] {
        var seen: Set<UUID> = []
        return (spaces.flatMap(\.workspaceTabs) + profiles.flatMap(\.favoriteTabs)).filter { seen.insert($0.id).inserted }
    }

    /// The tabs actually rendered. With a split on screen that is every one of
    /// its panes, not just the focused one: they are equally visible and
    /// suspending them would blank a page the user is looking at.
    var visibleTabIDs: Set<Tab.ID> {
        if let split = activeSplit { return Set(split.tabIDs) }
        return Set([activeTab?.id].compactMap { $0 })
    }

    /// Lets only the tabs on screen play media and pauses every other one, so a
    /// video or song stops when its tab is switched away from and never plays
    /// on in the background. Called on every change to what is visible -- a tab,
    /// space or split switch -- from the content pane, which is the one place
    /// that knows the switch has actually landed.
    func updateMediaSuspension() {
        let visible = visibleTabIDs
        for tab in allTabs {
            tab.setMediaSuspended(!visible.contains(tab.id))
        }
    }

    /// Tabs that must be loaded and unloaded together: the members of each
    /// split, in every space.
    var splitCohorts: [Set<Tab.ID>] {
        spaces.flatMap { $0.splits.layouts.map { Set($0.tabIDs) } }
    }

    // MARK: - Split view

    /// Each selected member brings its own independent split back on screen.
    var activeSplit: SplitLayout? { split(activeSpace) }

    func split(_ space: Space) -> SplitLayout? {
        space.splits.layout(containing: space.activeTabID)
    }

    func splitGroups(in space: Space) -> [SplitLayout] { space.splits.layouts }

    private func recordSplitUndoState(in space: Space? = nil) {
        let space = space ?? activeSpace
        lastSplitUndoState = SplitUndoState(spaceID: space.id, splits: space.splits, activeTabID: space.activeTabID)
    }

    var canUndoSplit: Bool { lastSplitUndoState?.spaceID == activeSpaceID }

    /// Undo retains all independent groups and never resurrects a closed tab.
    func undoSplit() {
        guard let undo = lastSplitUndoState, undo.spaceID == activeSpaceID else {
            unsplit()
            return
        }
        let space = activeSpace
        let current = SplitUndoState(spaceID: space.id, splits: space.splits, activeTabID: space.activeTabID)
        space.splits = undo.splits.retaining(Set(space.tabs.map(\.id)))
        if let tabID = undo.activeTabID, let tab = space.tabs.first(where: { $0.id == tabID }) {
            selectTab(tab)
        }
        lastSplitUndoState = current
        changes.send(.structure)
        changes.send(.activeTab)
        scheduleSave()
    }

    func isSticky(_ tabID: Tab.ID) -> Bool { activeSpace.splits.stickyTabIDs.contains(tabID) }

    func toggleStickPane(_ tabID: Tab.ID) {
        guard activeSpace.splits.layout(containing: tabID) != nil else { return }
        activeSpace.splits.toggleSticky(tabID)
        changes.send(.structure)
        changes.send(.activeTab)
        scheduleSave()
    }

    func stickActivePane() {
        guard let activeTab, activeSplit != nil else { return }
        toggleStickPane(activeTab.id)
    }

    func equalizeSplit() {
        guard let layout = activeSplit else { return }
        recordSplitUndoState()
        activeSpace.splits.update(layout.relaid(as: layout.grid))
        changes.send(.structure)
        changes.send(.activeTab)
        scheduleSave()
    }

    /// New split pages stay in their source profile, without domain routing.
    @discardableResult
    func openNewPageInSplit(_ url: URL, from source: Tab, grid: SplitLayout.Grid) -> Tab? {
        guard activeTab === source, activeSpace.tabs.contains(where: { $0 === source }),
              activeSplit?.isFull != true else { return nil }
        let tab = Tab(url: url, identity: activeSpace.identity)
        insert(tab, into: activeSpace, at: activeSpace.tabs.count, select: false)
        guard splitTabs([source, tab], grid: grid) else { closeTab(tab); return nil }
        selectTab(tab)
        return tab
    }

    func openLinkInSplit(_ url: URL, from sourceTab: Tab) {
        guard activeSpace.tabs.contains(where: { $0 === sourceTab }) else { return }
        if let split = activeSpace.splits.layout(containing: sourceTab.id),
           let otherID = split.tabIDs.first(where: { $0 != sourceTab.id }),
           let otherTab = activeSpace.tabs.first(where: { $0.id == otherID }) {
            otherTab.load(url)
            selectTab(otherTab)
            return
        }
        selectTab(sourceTab)
        openNewPageInSplit(url, from: sourceTab, grid: .sideBySide)
    }

    /// A new group preserves every unrelated group in this Space. Combining
    /// existing groups is atomic and always respects the four-pane limit.
    @discardableResult
    func splitTabs(_ tabs: [Tab], grid: SplitLayout.Grid = .grid) -> Bool {
        let space = activeSpace
        guard let first = tabs.first,
              tabs.allSatisfy({ candidate in space.tabs.contains { $0 === candidate } }) else { return false }
        var updated = space.splits
        guard updated.join(tabs.map(\.id), grid: grid) else { return false }
        guard updated != space.splits else { return true }
        recordSplitUndoState()
        space.splits = updated
        if let formed = space.splits.layout(containing: first.id),
           activeTab.map({ !formed.contains($0.id) }) ?? true { selectTab(first) }
        changes.send(.structure)
        changes.send(.activeTab)
        scheduleSave()
        return true
    }

    func relaySplit(as grid: SplitLayout.Grid) {
        guard let layout = activeSplit else { return }
        recordSplitUndoState()
        activeSpace.splits.update(layout.relaid(as: grid))
        changes.send(.structure)
        changes.send(.activeTab)
        scheduleSave()
    }

    func updateSplitLayout(_ layout: SplitLayout) {
        guard activeSplit?.tabIDs == layout.tabIDs, activeSpace.splits.update(layout) else { return }
        scheduleSave()
    }

    /// Shared Favorites may participate in splits in multiple Spaces. Removing
    /// one repairs every affected group, including groups in the background.
    func removeFromSplit(_ tab: Tab) {
        let owners = spaces.filter { $0.splits.layout(containing: tab.id) != nil }
        guard let undoOwner = owners.first(where: { $0.id == activeSpaceID }) ?? owners.first else { return }
        recordSplitUndoState(in: undoOwner)
        for space in owners {
            guard let removal = space.splits.remove(tab.id) else { continue }
            let survivors: [Tab.ID]
            switch removal {
            case .dissolved(let remaining): survivors = remaining
            case .resized(let layout): survivors = layout.tabIDs
            }
            if space === activeSpace, activeTab?.id == tab.id,
               let survivor = space.tabs.first(where: { $0.id == survivors.first }) {
                selectTab(survivor)
            }
        }
        changes.send(.structure)
        changes.send(.activeTab)
        scheduleSave()
    }

    func unsplit() {
        guard let active = activeTab, activeSplit != nil else { return }
        recordSplitUndoState()
        activeSpace.splits.dissolve(containing: active.id)
        changes.send(.structure)
        changes.send(.activeTab)
        scheduleSave()
    }

    /// Releases the web views of tabs that are not on screen. The tabs stay in
    /// the sidebar and come back exactly where they were when next shown.
    func suspend(_ tabs: [Tab]) {
        let protected = visibleTabIDs
        var suspended = 0
        for tab in tabs where !protected.contains(tab.id) {
            tab.unload()
            suspended += 1
        }
        Metrics.log("suspend asked=\(tabs.count) suspended=\(suspended) stillLoaded=\(allTabs.count { $0.isLoaded })")
    }

    // MARK: - History

    func historySuggestions(matching prefix: String, limit: Int = 8) async -> [HistoryEntry] {
        let identity = activeSpace.identity
        guard let database else { return [] }
        let result = (try? await database.suggestions(matching: prefix, limit: limit)) ?? []
        return activeSpace.identity == identity ? result : []
    }

    func topSites(limit: Int = 8) async -> [HistoryEntry] {
        let identity = activeSpace.identity
        guard let database else { return [] }
        let result = (try? await database.topSites(limit: limit)) ?? []
        return activeSpace.identity == identity ? result : []
    }

    @discardableResult
    func enrichArcTopSites(_ sites: [BrowserTopSite], for identity: Space.Identity) -> Int {
        guard !identity.isPrivate, let profile = profiles.first(where: { $0.identity == identity }) else { return 0 }
        let valid = sites.filter(\.isValid)
        if var existing = profile.preferences.arcTopSites {
            var changed = false
            for index in existing.indices where existing[index].favicon == nil {
                guard let candidate = valid.first(where: { $0.url == existing[index].url }),
                      let icon = candidate.favicon, icon.matches(existing[index].url) else { continue }
                existing[index].favicon = icon
                changed = true
            }
            if changed { profile.preferences.arcTopSites = existing; saveNow() }
            return 0
        }
        profile.preferences.arcTopSites = valid
        saveNow()
        return valid.count
    }

    func recentHistory(limit: Int = 100) async -> [HistoryEntry] {
        let identity = activeSpace.identity
        guard let database else { return [] }
        let result = (try? await database.recentHistory(limit: limit)) ?? []
        return activeSpace.identity == identity ? result : []
    }

    /// Forgets every visit. Asked for from the menu, so a failure is said out
    /// loud rather than left as a silent no-op the user would read as success.
    func clearHistory() {
        let profile = activeSpace.profile
        profile.preferences.arcTopSites = []
        if profile.preferences.folderCommandHistory != nil {
            profile.preferences.folderCommandHistory = profile.identity.isPrivate ? nil : FolderCommandHistory()
        }
        privateFolderCommands[profile.id] = nil
        saveNow()
        guard let database else { return }
        Task {
            do {
                try await database.clearHistory()
            } catch {
                reportHistoryFailure()
            }
        }
    }

    // MARK: - Bookmarks

    var activeTabIsBookmarked: Bool {
        guard let url = activeTab?.url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    func toggleBookmarkForActiveTab() {
        guard let database, let tab = activeTab else { return }
        let url = tab.url
        let title = tab.displayTitle
        let isBookmarked = activeTabIsBookmarked
        Task {
            do {
                if isBookmarked {
                    try await database.removeBookmark(url: url)
                } else {
                    try await database.addBookmark(url: url, title: title)
                }
            } catch {
                // `loadBookmarks` below re-reads the store, so on a failure the
                // star simply does not move. Without this it looks like the
                // page refused to be saved for no reason.
                showToast?(Toast(
                    symbolName: "exclamationmark.triangle",
                    message: isBookmarked ? "Could not remove the bookmark" : "Could not save the bookmark",
                    identity: "toggle-bookmark"
                ))
            }
            loadBookmarks()
        }
    }

    /// Pushes the Browsing pane's web preferences to every page already open.
    func applyWebPreferences() {
        for tab in allTabs {
            guard let preferences = tab.currentWebView?.configuration.preferences else { continue }
            preferences.minimumFontSize = settings.effectiveMinimumFontSize
            preferences.tabFocusesLinks = settings.tabFocusesLinks
        }
    }

    /// Removes history older than the retention setting, if there is one.
    ///
    /// Scheduled, not asked for: it runs at launch and when the setting
    /// changes. A failure is not something to interrupt someone with mid-task,
    /// and the next launch tries again, so this one stays best-effort.
    func pruneHistory() {
        guard let database, let cutoff = settings.historyRetention.cutoff() else { return }
        let profile = activeSpace.profile
        Task {
            do {
                try await database.deleteHistory(before: cutoff)
                if let sites = profile.preferences.arcTopSites, !sites.isEmpty {
                    var retained: [BrowserTopSite] = []
                    for site in sites {
                        if !(try await database.suggestions(matching: AddressFormatter.display(site.url), limit: 1)).isEmpty {
                            retained.append(site)
                        }
                    }
                    guard profile.preferences.arcTopSites == sites else { return }
                    profile.preferences.arcTopSites = retained
                    saveNow()
                }
            } catch { /* Retention remains best effort. */ }
        }
    }

    /// Says that history could not be cleared, once, wherever it was tried
    /// from. One identity, so Clear History and a reset do not stack two
    /// identical messages.
    private func reportHistoryFailure() {
        showToast?(Toast(
            symbolName: "exclamationmark.triangle",
            message: "Could not clear your history",
            identity: "clear-history"
        ))
    }

    /// Every space's identity that keeps data on disk.
    var storedIdentities: [Space.Identity] { profiles.map(\.identity) + [.standard] }

    /// Cookies gone from every space, on the schedule the user set.
    func deleteCookiesIfDue() {
        guard settings.cookieDeletion.isDue(lastDeletion: settings.lastCookieDeletion) else { return }
        let identities = storedIdentities
        Task {
            await WebsiteData.removeAll(types: WebsiteData.cookieTypes, for: identities)
            settings.lastCookieDeletion = .now
        }
    }

    /// Everything browsed: history, every space's website data, the closed
    /// tab list. Spaces, bookmarks and settings stay; they are the user's
    /// work, not the web's residue.
    func resetBrowsingData() async {
        closedTabs.removeAll()
        for profile in profiles {
            profile.preferences.arcTopSites = []
            if profile.preferences.folderCommandHistory != nil {
                profile.preferences.folderCommandHistory = profile.identity.isPrivate ? nil : FolderCommandHistory()
            }
        }
        privateFolderCommands.removeAll()
        saveNow()
        for identity in Set(storedIdentities) {
            guard let database = database(for: identity) else { continue }
            do {
                try await database.clearHistory()
            } catch {
                reportHistoryFailure()
            }
        }
        await WebsiteData.removeAll(for: storedIdentities)
        saveNow()
        settings.lastCookieDeletion = .now
        for tab in allTabs where tab.isLoaded { tab.reload() }
    }

    /// Clears the assigned profile's website data and refreshes its loaded
    /// pages in every Space, including shared Favorites.
    func clearSpaceData(for space: Space) async {
        let identity = space.identity
        await WebsiteData.clearSpaceData(for: identity)
        for tab in allTabs where tab.identity == identity && tab.isLoaded {
            tab.reload()
        }
        changes.send(.tabs)
    }

    /// Clears data for the currently active space.
    func clearActiveSpaceData() async {
        await clearSpaceData(for: activeSpace)
    }

    /// Adds bookmarks read from another browser's file, keeping the folders
    /// they came in. Duplicates by address update the title and folder rather
    /// than doubling up.
    func importBookmarks(_ entries: [BookmarkImporter.Entry]) async -> Int {
        guard let database, !entries.isEmpty else { return 0 }
        // `bookmarks()` orders by `created_at` descending, so the first entry
        // is stamped latest and stays first; a millisecond step keeps a whole
        // export in source order without spreading it across real time.
        let base = Date()
        let items = entries.enumerated().map { index, entry in
            (url: entry.url,
             title: entry.title,
             folder: entry.folderPath.joined(separator: "/"),
             date: base.addingTimeInterval(-Double(index) * 0.001))
        }
        let added: Int
        do {
            added = try await database.importBookmarks(items)
        } catch {
            // The pane that asked shows the count it gets back, and a bare "0"
            // with no explanation reads as "your file had nothing in it".
            added = 0
            showToast?(Toast(
                symbolName: "exclamationmark.triangle",
                message: "Could not import your bookmarks",
                identity: "import-bookmarks"
            ))
        }
        loadBookmarks()
        return added
    }

    /// Adds history read from another browser's file. The key each page is
    /// matched on is generated the same way a live visit's is, so imported
    /// pages surface in the omnibox exactly as browsed ones do. Returns how
    /// many pages were added.
    func importHistory(_ visits: [HistoryImporter.Visit]) async -> Int {
        guard let database, !visits.isEmpty else { return 0 }
        let items = visits.map { visit in
            (url: visit.url,
             title: visit.title,
             key: AddressFormatter.display(visit.url),
             date: visit.lastVisited)
        }
        return (try? await database.importVisits(items)) ?? 0
    }

    /// Opens the tabs another browser had, gathered into one new group in the
    /// active space. They are inserted straight into that space rather than
    /// through `newTab`, so routing rules do not scatter an import across
    /// spaces, and none is selected -- an import should not yank the user to a
    /// page. Restored (not fresh) tabs carry their title before they load, the
    /// way a relaunch does. Returns how many tabs were opened.
    @discardableResult
    func importTabs(_ imported: [TabSessionImporter.Tab], groupName: String) -> Int {
        guard !imported.isEmpty else { return 0 }
        let space = activeSpace
        var opened: [Tab] = []
        for item in imported {
            let snapshot = SessionSnapshot.Tab(
                url: item.url,
                title: item.title.isEmpty ? nil : item.title,
                groupID: nil,
                customName: nil,
                pinnedSiteID: nil,
                interactionState: nil
            )
            let tab = Tab(restoring: snapshot, identity: space.identity)
            insert(tab, into: space, at: space.tabs.count, select: false)
            opened.append(tab)
        }
        createGroup(named: groupName, containing: opened)
        return opened.count
    }

    /// Injects cookies read from another browser into the active space's own
    /// store, so the sites the user was signed into there are signed in here.
    /// The space's loaded pages reload so they pick the session up. Returns how
    /// many cookies were set. Cookies are per space, so an import lands in the
    /// space in front, not across all of them.
    func importCookies(_ cookies: [CookieImporter.Cookie]) async -> Int {
        let store = WebEnvironment.shared.dataStore(for: activeSpace.identity).httpCookieStore
        var count = 0
        for cookie in cookies {
            guard let httpCookie = Self.httpCookie(from: cookie) else { continue }
            await withCheckedContinuation { continuation in
                store.setCookie(httpCookie) { continuation.resume() }
            }
            count += 1
        }
        for tab in activeSpace.tabs where tab.isLoaded { tab.reload() }
        return count
    }

    private static func httpCookie(from cookie: CookieImporter.Cookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: cookie.path
        ]
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.isSecure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    /// The space links from other apps land in when the General pane says
    /// "Default space": the chosen one, else the first.
    var defaultSpace: Space {
        spaces.first { $0.id == settings.defaultSpaceID } ?? spaces[0]
    }

    /// Bookmarks every tab in the active space that is not bookmarked already.
    func bookmarkAllTabs() {
        guard let database else { return }
        let known = Set(bookmarks.map(\.url))
        let pages = activeSpace.tabs
            .filter { !known.contains($0.url) }
            .map { ($0.url, $0.displayTitle) }
        guard !pages.isEmpty else { return }
        Task {
            for (url, title) in pages {
                try? await database.addBookmark(url: url, title: title)
            }
            loadBookmarks()
        }
    }

    func removeBookmark(_ bookmark: Bookmark) {
        guard let database else { return }
        Task {
            try? await database.removeBookmark(url: bookmark.url)
            loadBookmarks()
        }
    }

    private func loadBookmarks() {
        let identity = activeSpace.identity
        guard let database else { bookmarks = []; changes.send(.bookmarks); return }
        Task {
            let loaded = (try? await database.bookmarks()) ?? []
            guard activeSpace.identity == identity else { return }
            guard loaded != bookmarks else { return }
            bookmarks = loaded
            changes.send(.bookmarks)
        }
    }

    func searchBookmarks(query: String, tag: String? = nil) async -> [Bookmark] {
        guard let database else { return [] }
        return (try? await database.searchBookmarks(query: query, tag: tag)) ?? []
    }

    func allBookmarkTags() async -> [String] {
        guard let database else { return [] }
        return (try? await database.allBookmarkTags()) ?? []
    }

    func setBookmarkTags(_ tags: [String], for url: URL) async {
        guard let database else { return }
        try? await database.setBookmarkTags(tags, for: url)
        loadBookmarks()
    }

    func addBookmarkTag(_ tag: String, to url: URL) async {
        guard let database else { return }
        try? await database.addBookmarkTag(tag, to: url)
        loadBookmarks()
    }

    func removeBookmarkTag(_ tag: String, from url: URL) async {
        guard let database else { return }
        try? await database.removeBookmarkTag(tag, from: url)
        loadBookmarks()
    }

    func findDuplicateBookmarks() async -> [[Bookmark]] {
        guard let database else { return [] }
        return (try? await database.findDuplicateBookmarks()) ?? []
    }

    @discardableResult
    func cleanupDuplicateBookmarks() async -> Int {
        guard let database else { return 0 }
        let count = (try? await database.cleanupDuplicateBookmarks()) ?? 0
        if count > 0 {
            loadBookmarks()
        }
        return count
    }

    func searchHistoryFullText(query: String, limit: Int = 50) async -> [FullTextHistoryResult] {
        guard let database else { return [] }
        return (try? await database.searchHistoryFullText(query: query, limit: limit)) ?? []
    }

    // MARK: - Persistence

    /// Writes the session after a short delay, collapsing bursts of changes.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes immediately. Called on quit, where a delayed write would be lost.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        try? sessionStore.save(snapshot())
    }

    /// Import completion includes the final profile preferences. Propagate a
    /// write failure to the importer instead of reporting an unsaved success.
    func commitArcImport() throws {
        saveTask?.cancel()
        saveTask = nil
        try sessionStore.save(snapshot())
    }

    func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            spaces: spaces.map { space in
                SessionSnapshot.Space(
                    id: space.id,
                    name: space.name,
                    // A private space keeps its name and its colour, and
                    // nothing it browsed: "not written to disk" includes the
                    // list of what was open.
                    tabs: space.isPrivate ? [] : space.tabs.map { $0.snapshot() },
                    activeTabIndex: space.isPrivate ? nil : space.activeTab.flatMap { space.index(of: $0) },
                    profileID: space.profile.id,
                    profileName: space.profile.name,
                    activeFavoriteID: space.activeTab?.pinnedSiteID,
                    identity: space.identity,
                    theme: space.theme.rawValue,
                    border: space.border,
                    look: space.look,
                    groups: space.groups.map {
                        SessionSnapshot.Group(
                            id: $0.id,
                            name: $0.name,
                            emoji: $0.emoji,
                            tint: $0.tint.hexString,
                            appearance: $0.appearance.isStandard ? nil : $0.appearance,
                            isCollapsed: $0.isCollapsed,
                            parentID: $0.parentID,
                            symbolName: $0.symbolName,
                            iconFileName: $0.iconFileName,
                            isLive: $0.isLive ? true : nil,
                            isLocked: $0.isLocked ? true : nil,
                            sidebarPosition: $0.sidebarPosition,
                            badgeIcon: $0.badgeIcon,
                            iconWasCustomized: $0.hasUserChosenIcon ? true : nil
                        )
                    },
                    pinnedSites: space.isPrivate ? nil : space.pinnedSites.map {
                        SessionSnapshot.Pinned(id: $0.id, url: $0.url, title: $0.title)
                    },
                    archiveHours: space.archiveHours,
                    // Written in the order archived, so the list restores the
                    // way it was built; the reading order is applied on the way
                    // out, in `archivedTabs(in:)`.
                    archivedTabs: space.isPrivate ? nil : archivedTabs
                        .filter { $0.spaceID == space.id }
                        .map { SessionSnapshot.Archived(tab: $0.snapshot, archivedAt: $0.archivedAt) },
                    downloadsDirectoryPath: space.downloadsDirectoryPath,
                    bookmarkFolder: space.bookmarkFolder,
                    enabledExtensionIDs: space.enabledExtensionIDs.map(Array.init),
                    passwordVaultAccount: space.passwordVaultAccount,
                    customProxy: space.customProxy,
                    searchEngineID: space.searchEngineID,
                    userAgent: space.userAgent,
                    sleepMinutes: space.sleepMinutes,
                    defaultZoom: space.defaultZoom,
                    icon: space.icon,
                    splits: space.isPrivate ? nil : space.splits.snapshot(tabIDs: space.tabs.map(\.id))
                )
            },
            activeSpaceIndex: spaces.firstIndex { $0.id == activeSpaceID } ?? 0,
            profiles: profiles.map { $0.snapshot() }
        )
    }

    /// Restores shared profile identities without moving or copying website data.
    static func spaces(from snapshot: SessionSnapshot) -> [Space]? {
        let legacyProfiles = snapshot.profiles ?? []
        var profilesByIdentity: [Space.Identity: BrowserProfile] = [:]
        var hasPreferences: Set<Space.Identity> = []
        for stored in legacyProfiles {
            let profile = BrowserProfile.restore(stored)
            if let existing = profilesByIdentity[profile.identity] { existing.mergeFavorites(from: profile) }
            else { profilesByIdentity[profile.identity] = profile }
            if stored.preferences != nil { hasPreferences.insert(profile.identity) }
        }

        func migratedIdentity(for stored: SessionSnapshot.Space) -> Space.Identity {
            guard let profile = legacyProfiles.first(where: { $0.id == stored.profileID }) else { return .standard }
            switch profile.kind {
            case .standard: return .standard
            case .isolated(let identifier): return .isolated(identifier)
            case .ephemeral: return .ephemeral(profile.id)
            }
        }

        func profile(for stored: SessionSnapshot.Space, identity: Space.Identity) -> BrowserProfile {
            let profile = profilesByIdentity[identity] ?? BrowserProfile(name: stored.profileName ?? (identity == .standard ? "Default" : stored.name), identity: identity)
            profilesByIdentity[identity] = profile
            if hasPreferences.insert(identity).inserted {
                profile.preferences = ProfilePreferences(archiveHours: stored.archiveHours, downloadsDirectoryPath: stored.downloadsDirectoryPath,
                    bookmarkFolder: stored.bookmarkFolder, enabledExtensionIDs: stored.enabledExtensionIDs.map(Set.init),
                    passwordVaultAccount: stored.passwordVaultAccount, customProxy: stored.customProxy,
                    searchEngineID: stored.searchEngineID, userAgent: stored.userAgent, sleepMinutes: stored.sleepMinutes, defaultZoom: stored.defaultZoom)
            }
            return profile
        }

        let spaces = snapshot.spaces.map { stored -> Space in
            let identity = stored.identity ?? migratedIdentity(for: stored)
            let profile = profile(for: stored, identity: identity)
            let legacyTheme = legacyProfiles.first { $0.id == stored.profileID }?.theme
            let space = Space(
                id: stored.id ?? UUID(),
                name: stored.name,
                identity: identity,
                profile: profile,
                theme: SpaceTheme(storedValue: stored.theme ?? legacyTheme),
                border: stored.border ?? .none,
                look: stored.look ?? SpaceLook(),
                archiveHours: stored.archiveHours,
                downloadsDirectoryPath: stored.downloadsDirectoryPath,
                bookmarkFolder: stored.bookmarkFolder,
                enabledExtensionIDs: stored.enabledExtensionIDs.map(Set.init),
                passwordVaultAccount: stored.passwordVaultAccount,
                customProxy: stored.customProxy,
                searchEngineID: stored.searchEngineID,
                userAgent: stored.userAgent,
                sleepMinutes: stored.sleepMinutes,
                defaultZoom: stored.defaultZoom
            )
            space.icon = stored.icon ?? .automatic
            if space.look.favoritesHintDismissed && profile.preferences.favoritesHintDismissed == nil {
                profile.preferences.favoritesHintDismissed = true
            }
            WebEnvironment.shared.setFonts(space.look.fonts, for: space.identity)
            let groups = (stored.groups ?? []).map {
                TabGroup(
                    id: $0.id,
                    name: $0.name,
                    emoji: $0.emoji,
                    tint: NSColor(hexString: $0.tint) ?? .controlAccentColor,
                    appearance: $0.appearance ?? .standard,
                    isCollapsed: $0.isCollapsed,
                    parentID: $0.parentID,
                    symbolName: $0.symbolName,
                    iconFileName: $0.iconFileName,
                    isLive: $0.isLive ?? false,
                    isLocked: $0.isLocked ?? false,
                    sidebarPosition: $0.sidebarPosition,
                    badgeIcon: $0.badgeIcon,
                    hasUserChosenIcon: $0.iconWasCustomized ?? false
                )
            }
            space.restore(
                groups: groups,
                pinnedSites: (stored.pinnedSites ?? []).map {
                    PinnedSite(id: $0.id, url: $0.url, title: $0.title)
                }
            )

            // A parent that did not survive the restore leaves a root folder
            // rather than an invisible one.
            let knownGroupIDs = Set(groups.map(\.id))
            for group in groups where group.parentID.map({ !knownGroupIDs.contains($0) }) ?? false {
                group.parentID = nil
            }
            var restoredSelection: [Tab] = []
            for tab in stored.tabs {
                var tab = tab
                // A tab whose group is gone becomes ungrouped rather than
                // invisible in the sidebar.
                if let id = tab.groupID, !knownGroupIDs.contains(id) { tab.groupID = nil }
                let restored = Tab(restoring: tab, identity: identity)
                space.insert(restored, at: space.workspaceTabs.count)
                restoredSelection.append(restored.pinnedSiteID.flatMap { space.tab(forPin: $0) } ?? restored)
            }
            if let favoriteID = stored.activeFavoriteID, let tab = space.tab(forPin: favoriteID) {
                space.setActiveTabID(tab.id)
            } else if let index = stored.activeTabIndex, restoredSelection.indices.contains(index) {
                space.setActiveTabID(restoredSelection[index].id)
            } else { space.setActiveTabID(space.tabs.first?.id) }
            if !space.isPrivate {
                space.splits = SplitCollection.restoring(stored.splits, tabIDs: restoredSelection.map(\.id))
            }
            return space
        }
        return spaces.isEmpty ? nil : spaces
    }

    /// Merges spaces, folders, pinned sites, and tabs from a snapshot into the current session.
    func mergeSnapshot(_ snapshot: SessionSnapshot, mergeTabs: Bool = true) {
        guard let incomingSpaces = Self.spaces(from: snapshot), !incomingSpaces.isEmpty else { return }

        for incomingSpace in incomingSpaces {
            if let existing = spaces.first(where: {
                $0.name.localizedCaseInsensitiveCompare(incomingSpace.name) == .orderedSame
            }) {
                // Merge groups
                let existingGroupIDs = Set(existing.groups.map(\.id))
                for group in incomingSpace.groups where !existingGroupIDs.contains(group.id) {
                    existing.addGroup(group)
                }

                // Merge pinned sites
                let existingPinnedURLs = Set(existing.pinnedSites.map(\.url.absoluteString))
                for pin in incomingSpace.pinnedSites where !existingPinnedURLs.contains(pin.url.absoluteString) {
                    existing.addPinnedSite(pin)
                }

                // Merge tabs if enabled
                if mergeTabs {
                    let existingURLs = Set(existing.tabs.map(\.url.absoluteString))
                    for tab in incomingSpace.tabs where !existingURLs.contains(tab.url.absoluteString) {
                        adopt(tab)
                        existing.insert(tab, at: existing.tabs.count)
                    }
                }
            } else {
                for tab in incomingSpace.tabs { adopt(tab) }
                if incomingSpace.tabs.isEmpty {
                    let tab = Tab(url: settings.newTabURL(isPrivate: incomingSpace.isPrivate), identity: incomingSpace.identity)
                    adopt(tab)
                    incomingSpace.insert(tab, at: 0)
                }
                spaces.append(incomingSpace)
            }
        }

        reconcileProfiles()
        changes.send(.spaces)
        changes.send(.tabs)
        changes.send(.structure)
        scheduleSave()
    }

    /// Replaces the session completely with the snapshot.
    /// Arc imports merge by stable source IDs, never by display name or URL.
    /// Repeated URLs are legitimate separate tabs and must survive the import.
    @discardableResult
    func applyArcSpaces(_ incoming: [SessionSnapshot.Space]) throws -> (tabs: Int, archived: Int, spaces: Int, folders: Int, favorites: Int) {
        var addedTabs = 0
        var addedArchived = 0
        var addedSpaces = 0
        var addedFolders = 0
        var addedFavorites = 0
        for stored in incoming {
            guard let id = stored.id, let identity = stored.identity else { continue }
            if let existing = spaces.first(where: { $0.id == id }), existing.identity != identity {
                throw ArcImportFailure.invalidSidebar
            }
            guard let built = Self.spaces(from: SessionSnapshot(spaces: [stored], activeSpaceIndex: 0))?.first else { continue }
            let space: Space
            if let existing = spaces.first(where: { $0.id == id }) {
                space = existing
                if !space.profile.hasCustomName, let name = stored.profileName, !name.isEmpty { space.profile.name = name }
                if space.icon == .automatic, !space.look.spaceIconWasCustomized, built.icon != .automatic {
                    space.icon = built.icon
                }
                if space.look.sidebarWidth == nil, let width = built.look.sidebarWidth {
                    space.look.sidebarWidth = width
                }
                if !space.look.dockVisibilityWasCustomized, !built.look.showsInDock {
                    space.look.showsInDock = false
                }
                // Enrich an older import only while its original accent is
                // unchanged. User colour/gradient edits always win.
                if space.theme == .custom, space.look.gradient == nil,
                   !space.look.importedChromeWasCustomized,
                   space.look.customColorHex?.lowercased() == built.look.customColorHex?.lowercased(),
                   let chrome = built.look.importedChrome {
                    space.look.importedChrome = space.look.importedChrome?.enrichingPalette(from: chrome) ?? chrome
                }
                if let engine = stored.searchEngineID { space.searchEngineID = engine }
                for group in built.groups where !space.groups.contains(where: { $0.id == group.id }) { space.addGroup(group); addedFolders += 1 }
                for group in built.groups {
                    guard let current = space.group(withID: group.id), !current.hasUserChosenIcon,
                          current.emoji == nil, current.iconFileName == nil,
                          current.symbolName == nil || current.symbolName == "folder" || current.symbolName == "arc.github.folder",
                          let badge = group.badgeIcon else { continue }
                    current.badgeIcon = badge
                }
                for pin in built.pinnedSites {
                    let before = space.pinnedSites.count
                    space.addPinnedSite(pin)
                    addedFavorites += space.pinnedSites.count - before
                }
            } else {
                space = built
                for tab in space.tabs { adopt(tab) }
                addedTabs += space.tabs.count
                addedFolders += space.groups.count
                addedFavorites += space.pinnedSites.count
                spaces.append(space)
                addedSpaces += 1
            }
            let known = Set(space.tabs.compactMap(\.importedSourceID)).union(space.profile.importedFavoriteIDs)
                .union(archivedTabs.filter { $0.spaceID == id }.compactMap { $0.snapshot.importedSourceID })
            let incomingIcons = Dictionary(stored.tabs.compactMap { tab -> (String, PageFavicon)? in
                guard let key = tab.importedSourceID, let icon = tab.favicon else { return nil }
                return (key, icon)
            }, uniquingKeysWith: { first, _ in first })
            for tab in space.tabs where tab.restoredFavicon == nil {
                if let key = tab.importedSourceID, let icon = incomingIcons[key], icon.matches(tab.url) {
                    tab.restoredFavicon = icon
                }
            }
            for tab in stored.tabs where tab.importedSourceID.map({ !known.contains($0) }) ?? false {
                let restored = Tab(restoring: tab, identity: identity)
                adopt(restored)
                space.insert(restored, at: space.tabs.count)
                addedTabs += 1
            }
            if space.activeTabID == nil { space.setActiveTabID(space.tabs.first?.id) }
            if space.tabs.isEmpty {
                let start = Tab(url: settings.newTabURL(isPrivate: false), identity: identity)
                adopt(start); space.insert(start, at: 0); space.setActiveTabID(start.id)
            }
            let knownArchive = Set(archivedTabs.filter { $0.spaceID == id }.compactMap { $0.snapshot.importedSourceID })
                .union(space.tabs.compactMap(\.importedSourceID))
            for record in stored.archivedTabs ?? [] where record.tab.importedSourceID.map({ !knownArchive.contains($0) }) ?? false {
                archivedTabs.append(ArchivedTab(snapshot: record.tab, spaceID: id, archivedAt: record.archivedAt))
                addedArchived += 1
            }
        }
        reconcileProfiles()
        changes.send(.spaces)
        changes.send(.tabs)
        changes.send(.structure)
        changes.send(.bookmarks)
        // A reported success must represent a durable session, not a debounced save.
        try sessionStore.save(snapshot())
        return (addedTabs, addedArchived, addedSpaces, addedFolders, addedFavorites)
    }

    /// Restore the selected Arc Spaces' relative order while leaving unrelated
    /// Spaces in their existing slots. The active Space keeps its identity.
    func applyArcSpaceOrder(_ orderedIDs: [UUID]) throws {
        let selected = Set(orderedIDs)
        let positions = spaces.indices.filter { selected.contains(spaces[$0].id) }
        let incoming = spaces.filter { selected.contains($0.id) }.sorted {
            (orderedIDs.firstIndex(of: $0.id) ?? .max) < (orderedIDs.firstIndex(of: $1.id) ?? .max)
        }
        guard positions.map({ spaces[$0].id }) != incoming.map(\.id) else { return }
        for (position, space) in zip(positions, incoming) { spaces[position] = space }
        changes.send(.spaces)
        changes.send(.structure)
        try sessionStore.save(snapshot())
    }

    func replaceWithSnapshot(_ snapshot: SessionSnapshot) {
        guard let newSpaces = Self.spaces(from: snapshot), !newSpaces.isEmpty else { return }

        for tab in allTabs { forget(tab) }
        tabSubscriptions.removeAll()
        self.spaces = newSpaces
        lastSplitUndoState = nil
        self.profiles = Self.profileList(from: snapshot, spaces: newSpaces)
        let index = min(max(snapshot.activeSpaceIndex, 0), newSpaces.count - 1)
        self.activeSpaceID = newSpaces[index].id

        for profile in profiles { for tab in profile.favoriteTabs { adopt(tab) } }
        for space in newSpaces {
            for tab in space.tabs { adopt(tab) }
            if space.tabs.isEmpty {
                let tab = Tab(url: settings.newTabURL(isPrivate: space.isPrivate), identity: space.identity)
                adopt(tab)
                space.insert(tab, at: 0)
            }
        }

        changes.send(.spaces)
        changes.send(.tabs)
        changes.send(.activeTab)
        changes.send(.structure)
        scheduleSave()
    }

    /// Fetches all bookmarks asynchronously.
    func allBookmarks() async -> [Bookmark] {
        guard let database else { return bookmarks }
        return (try? await database.bookmarks()) ?? bookmarks
    }

    /// Imports sync bookmarks into the database and reloads bookmarks.
    /// The newest visits, for the sync archive. Nothing when history is
    /// off, so a device that keeps no history contributes none.
    func recentVisits(limit: Int = SyncArchive.historyLimit) async -> [SyncVisit] {
        guard let database, !settings.historyDisabled else { return [] }
        return (try? await database.recentVisits(limit: limit)) ?? []
    }

    /// Visits from other devices; the ones already here are skipped.
    @discardableResult
    func importSyncVisits(_ visits: [SyncVisit]) async -> Int {
        guard let database, !visits.isEmpty else { return 0 }
        return (try? await database.mergeVisits(visits)) ?? 0
    }

    /// Merges bookmarks that arrived from another Mac.
    ///
    /// Background, and not something anyone asked for at this moment: the next
    /// sync carries the same records again, so a failure stays best-effort
    /// rather than raising a toast about a device nobody is looking at.
    func importSyncBookmarks(_ items: [SyncBookmark]) async {
        guard let database, !items.isEmpty else { return }
        let tuples = items.map { ($0.url, $0.title, $0.folder, $0.created) }
        try? await database.importBookmarks(tuples)
        loadBookmarks()
    }


    // MARK: - Bookkeeping

    private func insert(_ tab: Tab, into space: Space, at index: Int, select: Bool) {
        adopt(tab)
        space.insert(tab, at: index)
        if select || space.activeTabID == nil {
            space.setActiveTabID(tab.id)
        }

        if space.id == activeSpaceID {
            changes.send(.tabs)
            if space.activeTabID == tab.id { changes.send(.activeTab) }
        }
        scheduleSave()
    }

    private func adopt(_ tab: Tab) {
        tab.delegate = self
        tabSubscriptions[tab.id] = tab.didChange.sink { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.changes.send(.tab(tab))
            self.scheduleSave()
        }
    }

    /// Releases everything a tab holds: its WebKit content process first, then
    /// our subscription to it.
    private func forget(_ tab: Tab) {
        if tab.isInPictureInPicture {
            tab.exitPictureInPicture()
        }
        tab.unload()
        tab.delegate = nil
        tabSubscriptions[tab.id] = nil
        TabNameStore.shared.forget(tab.id)
    }
}

extension BrowserSession: TabDelegate {
    func tab(_ tab: Tab, requestsNewTabWith configuration: WKWebViewConfiguration) -> Tab {
        adoptChildTab(of: tab, configuration: configuration)
    }

    func tab(_ tab: Tab, didVisit url: URL, title: String) {
        onVisit?(tab, url)
        guard let database = database(for: tab.identity), !settings.historyDisabled, !tab.isPrivate else { return }
        let key = AddressFormatter.display(url)
        Task { try? await database.recordVisit(url: url, title: title, key: key) }
    }

    func tab(_ tab: Tab, didRetitle url: URL, to title: String) {
        guard let database = database(for: tab.identity), !settings.historyDisabled, !tab.isPrivate else { return }
        Task { try? await database.updateLatestVisitTitle(url: url, title: title) }
    }

    func tab(_ tab: Tab, requestsOpenInSplit url: URL) {
        openLinkInSplit(url, from: tab)
    }

    func tab(_ tab: Tab, didExtractContent content: String, for url: URL, title: String) {
        guard let database = database(for: tab.identity), !settings.historyDisabled, !tab.isPrivate else { return }
        // Indexing is never in the way of the page: background priority.
        Task(priority: .utility) { try? await database.indexVisitContent(url: url, title: title, content: content) }
    }
}

// MARK: - Live folders

/// The manager owns no tabs (D-LF, `LiveFolderManager`); this is where its
/// requests become tabs in the folder's own space.
extension BrowserSession: LiveFolderManagerDelegate {
    func liveFolderManager(
        _ manager: LiveFolderManager,
        openTabFor item: LiveFolderItem,
        inFolder folderID: TabGroup.ID
    ) -> Tab.ID? {
        // The folder's space, not the active one: a poll lands whenever it
        // lands, and the user may be looking somewhere else entirely.
        guard let space = spaces.first(where: { $0.group(withID: folderID) != nil }) else { return nil }
        // Restored rather than made from the URL alone, so the row carries the
        // item's title before the page has loaded -- or without it ever
        // loading, since a background tab builds no web view.
        let snapshot = SessionSnapshot.Tab(url: item.url, title: item.title, groupID: folderID)
        let tab = Tab(restoring: snapshot, identity: space.identity)
        insert(tab, into: space, at: space.tabs.count, select: false)
        return tab.id
    }

    func liveFolderManager(
        _ manager: LiveFolderManager,
        closeTabs tabIDs: [Tab.ID],
        inFolder folderID: TabGroup.ID
    ) {
        let gone = Set(tabIDs)
        for tab in allTabs where gone.contains(tab.id) && tab.groupID == folderID {
            closeTab(tab)
        }
    }

    func liveFolderManager(_ manager: LiveFolderManager, didChange folderID: TabGroup.ID) {
        changes.send(.structure)
    }
}
