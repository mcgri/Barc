// Modified for Barc: compact sidebar themes and profile-owned browsing data, 2026-10-24.
import AppKit

/// A named tab layout. Its profile owns the browsing identity and Favorites;
/// several Spaces can use one profile without duplicating its open Favorites.
///
/// The mutators below are called only by `BrowserSession`, which is what
/// announces every change to the UI. Mutating a `Space` directly would change
/// the model without telling anyone.
@MainActor
final class Space: Identifiable {
    /// Where a space's website data lives.
    ///
    /// Encoded by case name, so a session file written by an earlier build
    /// that stored these on profiles still decodes.
    enum Identity: Codable, Hashable, Sendable {
        /// WebKit's default store. Everything browsed before spaces had their
        /// own identity lives here, so the first space keeps using it rather
        /// than migrating.
        case standard
        /// Its own persistent store on disk, keyed by this identifier.
        case isolated(UUID)
        /// Nothing is written to disk; the data is gone when the app quits.
        /// The identifier only keeps two private spaces' stores apart.
        case ephemeral(UUID)

        var isPrivate: Bool {
            if case .ephemeral = self { return true }
            return false
        }

        /// A fresh identity that keeps its data.
        static func makeIsolated() -> Identity { .isolated(UUID()) }
        /// A fresh identity that keeps nothing.
        static func makeEphemeral() -> Identity { .ephemeral(UUID()) }
    }

    /// The longest a space's name may be.
    ///
    /// A space's name is a label, not a sentence: it is read in the sidebar
    /// header, in the space menu, on a card in Settings and in every window
    /// title that names it. Nothing stopped a name being a paragraph, and a
    /// paragraph turned every one of those places into an ellipsis.
    ///
    /// Twenty-four characters, because that is what fits: it holds the names
    /// people actually use ("Personal", "Work", "Daily Dashboard", "Read Later
    /// BF9059") with room to spare, and it is short enough that a card sized
    /// to hold the longest legal name is still a card rather than a column.
    /// `SpaceGrid` takes its cell width from exactly this number.
    nonisolated static let maximumNameLength = 24

    /// A name as it will actually be stored: trimmed, and cut to the limit.
    ///
    /// Applied in `BrowserSession` rather than at each call site, so a name
    /// arriving from the companion iPhone or from a restored session file is
    /// held to the same rule as one typed into a sheet.
    nonisolated static func clampName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumNameLength else { return trimmed }
        return String(trimmed.prefix(maximumNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The space's identifier, stable across launches.
    ///
    /// Restored from the session file rather than made fresh each time:
    /// Settings stores the default space by this id, and an id that changed at
    /// every launch meant "Default space" quietly fell back to the first space
    /// on the next one -- taking "Open external links in: Default space" with
    /// it. A session written before ids were saved gives its spaces new ones,
    /// once.
    let id: UUID

    var name: String
    private(set) var profile: BrowserProfile
    var identity: Identity { profile.identity }
    var favoritesHintDismissed: Bool { profile.preferences.favoritesHintDismissed ?? look.favoritesHintDismissed }
    /// What the window looks like while this space is the one in front.
    var theme: SpaceTheme
    /// The rim around the window while this space is in front. Per space,
    /// like the colour, and for the same reason: it is how the window says
    /// which identity it is browsing as.
    var border: WindowBorder
    /// Appearance, fonts, bars and full-screen behaviour, all this space's own.
    var look: SpaceLook

    /// The space's colour: its gradient's first stop, its theme's, or the one
    /// the user picked. The single colour a dot or a rim needs; the chrome's
    /// wash uses the whole gradient when there is one (`washGradient(for:)`).
    var color: NSColor {
        if let color = look.sidebarTheme?.colors.first { return color.nsColor }
        if let gradient = look.gradient { return gradient.startColor }
        return theme == .custom ? (look.customColor ?? SpaceTheme.default.color) : theme.color
    }

    /// The solid wash over the chrome, or nil for the plain window. When a
    /// gradient is set this is its first stop at wash strength, which stands in
    /// wherever only one colour fits and is the base the gradient fades over.
    var wash: NSColor? {
        // Neutral with no gradient paints nothing; anything with a colour of
        // its own washes at the space's own strength.
        guard look.gradient != nil || theme.tintsChrome else { return nil }
        if let chrome = activeImportedChrome {
            return chrome.color.nsColor.withAlphaComponent(CGFloat(chrome.color.alpha * chrome.intensity * look.washOpacity) * 0.8)
        }
        if theme == .custom { return color.withAlphaComponent(CGFloat(look.washOpacity) * 0.75) }
        return SpaceTheme.wash(of: color, opacity: CGFloat(look.washOpacity))
    }

    var activeImportedChrome: ImportedChrome? {
        guard theme == .custom, look.gradient == nil,
              !(look.allowsWebsiteThemeColor && activeTab?.themeColor != nil) else { return nil }
        if let style = look.sidebarTheme {
            let dark = look.appearance == .dark || (look.appearance == .system && NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            return style.chrome(dark: dark)
        }
        return look.importedChrome
    }

    /// Space symbols must remain visible over the sidebar's wash. Arc keeps
    /// their contrasting palette separately from the pale accent swatch.
    var sidebarIconColor: NSColor {
        guard case .symbol = icon else { return color }
        let chrome = activeImportedChrome
        let light = chrome?.lightMaxContrast?.nsColor ?? color
        let dark = chrome?.darkMaxContrast?.nsColor ?? color
        return NSColor(name:nil) { appearance in
            appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Standard folders use the imported contrast palette with any Space
    /// icon. Without a complete palette, the glyph keeps its ordinary tint.
    var sidebarFolderColor: NSColor? {
        guard let chrome = activeImportedChrome,
              let light = chrome.lightMaxContrast?.nsColor,
              let dark = chrome.darkMaxContrast?.nsColor else { return nil }
        return NSColor(name:nil) { appearance in
            appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Retain Arc's semantic focus colour, which differs from its background
    /// and accent. New themes use their own colour rather than the Mac accent.
    var commandFocusColor: NSColor {
        let chrome = activeImportedChrome
        let fallback = color.blended(withFraction: 0.35, of: .gray) ?? color
        let light = chrome?.lightFocus?.nsColor ?? fallback
        let dark = chrome?.darkFocus?.nsColor ?? fallback
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// URL text has a softer highlight than the selected result underneath it.
    var commandTextSelectionColor: NSColor {
        let chrome = activeImportedChrome
        let fallback = color.blended(withFraction: 0.35, of: .gray) ?? color
        let lightFocus = chrome?.lightFocus?.nsColor ?? fallback
        let darkFocus = chrome?.darkFocus?.nsColor ?? fallback
        let light = chrome?.lightSubtitle?.nsColor ?? lightFocus.blended(withFraction: 0.2, of: .white) ?? lightFocus
        let dark = chrome?.darkSubtitle?.nsColor ?? darkFocus.blended(withFraction: 0.35, of: .gray) ?? darkFocus
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    var chromeGrain: Double { (activeImportedChrome?.noise ?? 0) * look.washOpacity }

    /// The solid wash while this tab is in front: the page's own colour if the
    /// space lets pages do that and this one declares one, else the space's.
    func wash(for tab: Tab?) -> NSColor? {
        if look.allowsWebsiteThemeColor, let pageColour = tab?.themeColor {
            return SpaceTheme.wash(of: pageColour)
        }
        return wash
    }

    /// The gradient wash while this tab is in front, or nil for a solid one. A
    /// page that declares its own colour takes the wash over (as a solid), so
    /// the gradient yields to it exactly as the solid wash does.
    func washGradient(for tab: Tab?) -> WashGradient? {
        if let style = look.sidebarTheme, style.colors.count > 1,
           !(look.allowsWebsiteThemeColor && tab?.themeColor != nil) {
            return WashGradient(startHex: style.colors[0].nsColor.hexString, endHex: style.colors[1].nsColor.hexString,
                direction: .down, opacity: CGFloat(style.intensity * look.washOpacity),
                additionalColors: style.colors.dropFirst(2).map { $0.nsColor.hexString }, usesFullColor: true)
        }
        guard let gradient = look.gradient else { return nil }
        if look.allowsWebsiteThemeColor, tab?.themeColor != nil { return nil }
        return WashGradient(startHex: gradient.startHex, endHex: gradient.endHex, direction: gradient.direction, opacity: CGFloat(look.washOpacity))
    }

    /// Whether the space has a colour of its own -- a solid tint or a gradient
    /// -- and is not deferring to the page's colour. This is the "Customized"
    /// appearance; the plain presets and Website are not it.
    var isCustomized: Bool {
        !look.allowsWebsiteThemeColor && (look.gradient != nil || theme.tintsChrome)
    }

    /// The rim to actually draw around the window. The border is a trapping of a
    /// customised space's colours, so a plain preset or a website-coloured space
    /// shows none -- even if one is still stored, ready for when the space is
    /// customised again.
    var effectiveBorder: WindowBorder {
        isCustomized ? border : .none
    }

    /// What the user put on this space: an emoji, a symbol, a picture of their
    /// own, or the coloured dot every space started with.
    var icon: SpaceIcon = .automatic

    /// The space's mark, at whatever size the caller draws it.
    ///
    /// Still called `dotImage` because the dot is still what most spaces show
    /// and what every one of them falls back to. Every place that shows a
    /// space -- the sidebar header, the space menu, the card in Settings, the
    /// window list, Little Arc -- goes through here, which is why an icon set
    /// once turns up in all of them without any of them knowing icons exist.
    func dotImage(side: CGFloat = 10) -> NSImage {
        icon.image(color: color, title: nameForIcon, side: side)
    }

    /// Menu symbols follow the selected menu text; emoji and custom pictures keep their colors.
    func menuImage() -> NSImage {
        let image = dotImage(side: 14)
        if case .symbol(let name) = icon, FolderSymbols.image(named: name) != nil {
            image.isTemplate = true
        }
        return image
    }

    /// What VoiceOver reads for the mark. The space's own name when it has
    /// one, because "Work" says more than the colour's name does; the colour
    /// only has to stand in for an unnamed space.
    private var nameForIcon: String {
        name.isEmpty ? theme.title : name
    }

    /// Shown beside the name, so it is never a surprise that nothing here is
    /// being kept.
    var isPrivate: Bool { identity.isPrivate }

    var splits = SplitCollection() {
        didSet { profile.updateFavoriteSplits(before:oldValue,after:splits) }
    }
    /// Source units already considered, including those later separated locally.
    var importedSplitIDs: Set<UUID> = []

    private(set) var workspaceTabs: [Tab] = []
    var tabs: [Tab] {
        profile.favoriteTabs.isEmpty ? workspaceTabs : workspaceTabs + profile.favoriteTabs
    }
    private(set) var activeTabID: Tab.ID?

    /// Named clusters inside this space, in sidebar order. Tabs point at a
    /// group rather than being held by one, so grouping never reorders them.
    private(set) var groups: [TabGroup] = []

    /// Sites pinned to the tile strip at the top of the sidebar.
    var pinnedSites: [PinnedSite] { profile.pinnedSites }
    /// Per-space auto-archive delay in hours, or nil to follow global preferences.
    /// Setting to 0 disables auto-archiving for this space.
    var archiveHours: Int? {
        get { profile.preferences.archiveHours }
        set { profile.preferences.archiveHours = newValue }
    }

    /// Per-space downloads directory override path (e.g. "~/Downloads/Work"), or nil for global Downloads.
    var downloadsDirectoryPath: String? {
        get { profile.preferences.downloadsDirectoryPath }
        set { profile.preferences.downloadsDirectoryPath = newValue }
    }

    /// Dedicated bookmarks folder shown on this space's bookmarks bar, or nil for all bookmarks.
    var bookmarkFolder: String? {
        get { profile.preferences.bookmarkFolder }
        set { profile.preferences.bookmarkFolder = newValue }
    }

    /// Set of extension IDs enabled in this space. If nil, all globally enabled extensions run.
    var enabledExtensionIDs: Set<UUID>? {
        get { profile.preferences.enabledExtensionIDs }
        set { profile.preferences.enabledExtensionIDs = newValue }
    }

    /// Account or vault name used by password managers/extensions for this space (e.g. "Work", "Personal").
    var passwordVaultAccount: String? {
        get { profile.preferences.passwordVaultAccount }
        set { profile.preferences.passwordVaultAccount = newValue }
    }

    /// Space-specific network proxy override. When nil or disabled, browser global proxy settings apply.
    var customProxy: ProxySettings? {
        get { profile.preferences.customProxy }
        set { profile.preferences.customProxy = newValue }
    }

    /// The search engine this space's omnibox uses, by id, or nil for the
    /// one in Settings.
    var searchEngineID: String? {
        get { profile.preferences.searchEngineID }
        set { profile.preferences.searchEngineID = newValue }
    }
    /// A user agent for every page in this space, or nil for the default.
    /// A per-site choice in Websites still wins over it.
    var userAgent: String? {
        get { profile.preferences.userAgent }
        set { profile.preferences.userAgent = newValue }
    }
    /// Minutes before a background tab here sleeps: nil follows Settings,
    /// 0 never sleeps.
    var sleepMinutes: Int? {
        get { profile.preferences.sleepMinutes }
        set { profile.preferences.sleepMinutes = newValue }
    }
    /// The zoom pages here start at, as a `SiteSettings` zoom step such as
    /// "1.25", or nil for the default. A per-site zoom still wins over it.
    var defaultZoom: String? {
        get { profile.preferences.defaultZoom }
        set { profile.preferences.defaultZoom = newValue }
    }

    /// Effective proxy settings for this space: space-specific if enabled, otherwise global.
    var effectiveProxy: ProxySettings? {
        if let custom = customProxy, custom.enabled {
            return custom
        }
        let global = Settings.shared.proxySettings
        return global.enabled ? global : nil
    }

    var effectiveDownloadsDirectory: URL {
        if let path = downloadsDirectoryPath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue {
                return URL(fileURLWithPath: expanded)
            }
            if (try? FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)) != nil {
                return URL(fileURLWithPath: expanded)
            }
        }
        return DownloadDestination.downloadsDirectory() ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads")
    }

    var effectivePasswordAccount: String {
        let trimmed = passwordVaultAccount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? profile.name : trimmed
    }

    init(
        id: UUID = UUID(),
        name: String,
        identity: Identity,
        profile: BrowserProfile? = nil,
        theme: SpaceTheme = .default,
        border: WindowBorder = .none,
        look: SpaceLook = SpaceLook(),
        archiveHours: Int? = nil,
        downloadsDirectoryPath: String? = nil,
        bookmarkFolder: String? = nil,
        enabledExtensionIDs: Set<UUID>? = nil,
        passwordVaultAccount: String? = nil,
        customProxy: ProxySettings? = nil,
        searchEngineID: String? = nil,
        userAgent: String? = nil,
        sleepMinutes: Int? = nil,
        defaultZoom: String? = nil
    ) {
        self.id = id
        self.name = name
        self.profile = profile ?? BrowserProfile(name: identity == .standard ? "Default" : name, identity: identity)
        self.theme = theme
        self.border = border
        self.look = look
        if profile == nil {
            self.profile.preferences = ProfilePreferences(archiveHours: archiveHours, downloadsDirectoryPath: downloadsDirectoryPath,
                bookmarkFolder: bookmarkFolder, enabledExtensionIDs: enabledExtensionIDs, passwordVaultAccount: passwordVaultAccount,
                customProxy: customProxy, searchEngineID: searchEngineID, userAgent: userAgent, sleepMinutes: sleepMinutes, defaultZoom: defaultZoom)
        }
    }

    /// The idle time before a tab here sleeps, or nil for never; falls back
    /// to `global` when the space has no say.
    func sleepDelay(global: TimeInterval?) -> TimeInterval? {
        guard let sleepMinutes else { return global }
        return sleepMinutes > 0 ? TimeInterval(sleepMinutes) * 60 : nil
    }

    var activeTab: Tab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    func index(of tab: Tab) -> Int? {
        tabs.firstIndex { $0.id == tab.id }
    }

    // MARK: - Mutators (BrowserSession only)

    func insert(_ tab: Tab, at index: Int) {
        if tab.pinnedSiteID != nil, let canonical = profile.adoptFavorite(tab) {
            // Old per-Space copies can have different navigations or notes.
            // Preserve a divergent page as an ordinary tab when coalescing.
            if canonical === tab || BrowserProfile.sameFavoriteCopy(canonical, tab) { return }
        }
        if tab.pinnedSiteID != nil { tab.setPinnedSiteID(nil) }
        guard !workspaceTabs.contains(where: { $0 === tab }) else { return }
        workspaceTabs.insert(tab, at: min(max(index, 0), workspaceTabs.count))
    }

    /// Removes the tab and returns the index it occupied, or nil if absent.
    @discardableResult
    func remove(_ tab: Tab) -> Int? {
        guard let index = index(of: tab) else { return nil }
        if let local = workspaceTabs.firstIndex(where: { $0 === tab }) { workspaceTabs.remove(at: local) }
        else { profile.removeFavorite(tab) }
        return index
    }

    /// `destination` is a pre-removal insertion point, matching the index a
    /// table view reports from a drop.
    func move(from source: Int, to destination: Int) {
        guard workspaceTabs.indices.contains(source) else { return }
        let tab = workspaceTabs.remove(at: source)
        let target = source < destination ? destination - 1 : destination
        workspaceTabs.insert(tab, at: min(max(target, 0), workspaceTabs.count))
    }

    func setActiveTabID(_ id: Tab.ID?) {
        activeTabID = id
    }

    /// Puts the same tabs in a new order. Refused unless `ordered` is exactly
    /// the tabs already here, so a sort can never add or lose one.
    @discardableResult
    func replaceTabs(with ordered: [Tab]) -> Bool {
        guard ordered.count == tabs.count, Set(ordered.map(\.id)) == Set(tabs.map(\.id)) else { return false }
        workspaceTabs = ordered.filter { $0.pinnedSiteID == nil }
        return true
    }

    // MARK: - Groups

    func group(withID id: TabGroup.ID) -> TabGroup? {
        groups.first { $0.id == id }
    }

    func addGroup(_ group: TabGroup) {
        groups.append(group)
    }

    /// Removing a group returns its tabs to the ungrouped list rather than
    /// closing them. Filing something away should never destroy it.
    func removeGroup(_ group: TabGroup) {
        groups.removeAll { $0.id == group.id }
        for tab in tabs where tab.groupID == group.id {
            tab.setGroupID(nil)
        }
    }

    /// Takes a group out of this space's list without touching its tabs -- used
    /// when the group and its tabs move to another space together, where they
    /// must keep pointing at each other. Unlike `removeGroup`, it does not
    /// return the tabs to the ungrouped list.
    func detachGroup(_ group: TabGroup) {
        groups.removeAll { $0.id == group.id }
    }

    /// Reorders a group so it sits just before `other`, or at the end of the
    /// list when `other` is nil. The sidebar draws top-level groups in this
    /// array's order, so moving the entry is what moves the group.
    func moveGroup(_ group: TabGroup, before other: TabGroup?) {
        guard let from = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let moved = groups.remove(at: from)
        if let other, let to = groups.firstIndex(where: { $0.id == other.id }) {
            groups.insert(moved, at: to)
        } else {
            groups.append(moved)
        }
    }

    func tabs(in group: TabGroup) -> [Tab] {
        tabs.filter { $0.groupID == group.id }
    }

    var ungroupedTabs: [Tab] {
        tabs.filter { $0.groupID == nil }
    }

    /// The tab a pinned shortcut is showing, if it has opened one.
    func tab(forPin id: UUID) -> Tab? {
        tabs.first { $0.pinnedSiteID == id }
    }

    /// Tabs that belong in the list. A pinned shortcut is represented by its
    /// tile, so listing its tab as well shows the same thing twice.
    var listedTabs: [Tab] {
        tabs.filter { $0.pinnedSiteID == nil }
    }

    /// Presentation only: the empty content owner stays in the saved session.
    var sidebarVisibleTabs: [Tab] { listedTabs.filter { !$0.isSidebarPlaceholder } }

    // MARK: - Pinned sites

    func addPinnedSite(_ site: PinnedSite) {
        profile.addPinnedSite(site)
    }

    func removePinnedSite(_ site: PinnedSite) {
        profile.removePinnedSite(site)
    }

    func movePinnedSite(from source: Int, to destination: Int) {
        profile.movePinnedSite(from: source, to: destination)
    }

    func restore(groups: [TabGroup], pinnedSites: [PinnedSite]) {
        self.groups = groups
        for site in pinnedSites { profile.addPinnedSite(site) }
    }

    func useProfile(_ profile: BrowserProfile) { self.profile = profile }

    func promoteFavorite(_ tab: Tab) {
        guard profile.adoptFavorite(tab) != nil else { return }
        tab.setGroupID(nil)
        workspaceTabs.removeAll { $0 === tab }
    }
}
