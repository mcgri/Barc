// Modified for Barc: archived split groups and durable independent layouts, 2026-10-25.
// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit

/// A serialisable picture of every space and tab.
///
/// Deliberately a value type with no references to live objects: writing it out
/// cannot be affected by what the browser does next.
struct SessionSnapshot: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var url: URL
        var title: String?
        /// Which group the tab was filed under. Absent for ungrouped tabs and
        /// for sessions written before groups existed.
        var groupID: UUID?
        /// The name the user gave this tab, which overrides the page title.
        /// Absent for tabs that were never renamed, and for sessions written
        /// before renaming existed.
        var customName: String?
        /// The pinned shortcut this tab belongs to, if any. Absent for ordinary
        /// tabs and for sessions written before shortcuts owned their tab.
        var pinnedSiteID: UUID?
        /// `WKWebView.interactionState`, which carries scroll position, form
        /// contents and the back-forward list. Absent when the tab was never
        /// shown, in which case the URL alone is enough.
        var interactionState: Data?
        /// When the tab was last on screen. Absent in sessions written before
        /// the idle clock was persisted, which restore as "just now".
        ///
        /// Persisted because archiving measures in days: without it, quitting
        /// on Friday would hand every tab a fresh clock on Monday and nothing
        /// would ever age out of a sidebar that is closed every evening.
        var lastActiveAt: Date?
        /// Absent for tabs the user never locked, and for sessions written
        /// before the locks existed.
        var keepsAwake: Bool?
        var keepsInSidebar: Bool?
        /// The tab refuses to close. Absent for the ordinary tab, and for
        /// sessions written before the lock existed -- which restore unlocked,
        /// the only safe direction: a lock nobody set is a tab nobody can shut.
        var isLocked: Bool?
        /// The colour the user tagged the tab with. Absent when untagged.
        var colorTag: String?
        /// A note the user attached. Absent when there is none.
        var note: String?
        /// Seconds between automatic reloads. Absent when the tab does not.
        var autoReloadSeconds: Int?
        /// An emoji in place of the favicon. Absent when there is none.
        var emoji: String?
        /// Stable source identifier for repeatable imports. Never a page URL or secret.
        var importedSourceID: String? = nil
        var sidebarPosition: Int? = nil
        var favicon: PageFavicon? = nil
        /// Optional custom sidebar symbol and the original retained page address.
        var sidebarSymbolName: String? = nil
        var pinnedPageURL: URL? = nil
    }

    struct Split: Codable, Equatable, Sendable {
        var layout: SplitLayout
        var tabIndices: [Int]
        var stickyTabIndex: Int?
        var id: UUID? = nil
        var focusedTabIndex: Int? = nil
    }

    struct Space: Codable, Equatable {
        var name: String
        /// Written by builds that had a space switcher row with an icon and a
        /// colour per space. Read for compatibility, never written.
        var symbolName: String?
        var tint: String?
        var tabs: [Tab]
        var activeTabIndex: Int?
        /// The space's own identifier. Absent in sessions written before a
        /// space's id was saved, which are given new ones on the way in.
        var id: UUID?
        /// The profile registry entry assigned to this layout.
        var profileID: UUID?
        var profileName: String?
        var activeFavoriteID: UUID?
        /// Where this space's website data lives. Absent in sessions written
        /// before a space was its own identity, which are migrated from
        /// `profileID`.
        var identity: Barc.Space.Identity?
        /// Absent in sessions written before spaces had a colour, which
        /// restore onto the default one.
        var theme: String?
        /// The rim around the window. Absent in sessions written before
        /// spaces had one, which restore with none.
        var border: WindowBorder?
        /// Appearance, fonts and bars. Absent in sessions written before a
        /// space had them, which restore with the defaults.
        var look: SpaceLook?
        /// Absent in sessions written before groups and pins existed.
        var groups: [Group]?
        var pinnedSites: [Pinned]?
        var archiveHours: Int?
        /// Tabs auto-archived out of this space's sidebar. Held on the space
        /// rather than at the top level because a snapshot identifies spaces by
        /// position, so anything filed by space id would not survive a reorder.
        /// Absent in sessions written before archiving existed.
        var archivedTabs: [Archived]?
        var downloadsDirectoryPath: String?
        var bookmarkFolder: String?
        var enabledExtensionIDs: [UUID]?
        var passwordVaultAccount: String?
        var customProxy: ProxySettings?
        /// Per-space overrides added later; absent means "follow Settings".
        var searchEngineID: String?
        var userAgent: String?
        var sleepMinutes: Int?
        var defaultZoom: String?
        /// The emoji, symbol or picture on this space. Absent in sessions
        /// written before spaces had icons, which restore on the dot.
        var icon: SpaceIcon?
        var splits: [Split]?
        var importedSplitIDs: [UUID]? = nil

        init(
            id: UUID? = nil,
            name: String,
            symbolName: String? = nil,
            tint: String? = nil,
            tabs: [Tab] = [],
            activeTabIndex: Int? = nil,
            profileID: UUID? = nil,
            profileName: String? = nil,
            activeFavoriteID: UUID? = nil,
            identity: Barc.Space.Identity? = nil,
            theme: String? = nil,
            border: WindowBorder? = nil,
            look: SpaceLook? = nil,
            groups: [Group]? = nil,
            pinnedSites: [Pinned]? = nil,
            archiveHours: Int? = nil,
            archivedTabs: [Archived]? = nil,
            downloadsDirectoryPath: String? = nil,
            bookmarkFolder: String? = nil,
            enabledExtensionIDs: [UUID]? = nil,
            passwordVaultAccount: String? = nil,
            customProxy: ProxySettings? = nil,
            searchEngineID: String? = nil,
            userAgent: String? = nil,
            sleepMinutes: Int? = nil,
            defaultZoom: String? = nil,
            icon: SpaceIcon? = nil,
            splits: [Split]? = nil,
            importedSplitIDs: [UUID]? = nil
        ) {
            self.id = id
            self.name = name
            self.symbolName = symbolName
            self.tint = tint
            self.tabs = tabs
            self.activeTabIndex = activeTabIndex
            self.profileID = profileID
            self.profileName = profileName
            self.activeFavoriteID = activeFavoriteID
            self.identity = identity
            self.theme = theme
            self.border = border
            self.look = look
            self.groups = groups
            self.pinnedSites = pinnedSites
            self.archiveHours = archiveHours
            self.archivedTabs = archivedTabs
            self.downloadsDirectoryPath = downloadsDirectoryPath
            self.bookmarkFolder = bookmarkFolder
            self.enabledExtensionIDs = enabledExtensionIDs
            self.passwordVaultAccount = passwordVaultAccount
            self.customProxy = customProxy
            self.searchEngineID = searchEngineID
            self.userAgent = userAgent
            self.sleepMinutes = sleepMinutes
            self.defaultZoom = defaultZoom
            self.icon = icon
            self.splits = splits
            self.importedSplitIDs = importedSplitIDs
        }
    }

    /// A tab that left the sidebar on its own. Kept whole, so restoring it
    /// brings back the scroll position and back-forward list too, not just an
    /// address.
    struct Archived: Codable, Equatable {
        var tab: Tab
        var archivedAt: Date
        /// A split is one archive entry. Slots in its layout refer to this
        /// entry's pages, starting with `tab`, rather than live sidebar slots.
        /// Missing fields keep old single-page archives readable.
        var additionalTabs: [Tab]? = nil
        var split: Split? = nil

        var tabs: [Tab] { [tab] + (additionalTabs ?? []) }
    }

    struct Group: Codable, Equatable {
        var id: UUID
        var name: String
        var emoji: String?
        var tint: String
        /// How the group's plate is coloured. Absent for the default plate and
        /// for sessions written before groups could be themed.
        var appearance: TabGroupAppearance?
        var isCollapsed: Bool
        /// The folder this one is filed inside. Absent for root folders and for
        /// sessions written before folders nested.
        var parentID: UUID?
        /// An SF Symbol chosen instead of an emoji.
        var symbolName: String?
        /// A picture chosen instead of either, named in `SpaceIconStore`.
        /// Absent for sessions written before folders could carry one.
        var iconFileName: String?
        /// Whether a provider maintains this folder's contents. The provider
        /// itself lives in `live-folders.json`, keyed by this group's id.
        var isLive: Bool?
        /// The folder refuses to be deleted. Absent for the ordinary folder and
        /// for sessions written before the lock existed.
        var isLocked: Bool?
        var sidebarPosition: Int? = nil
        var badgeIcon: Data? = nil
        var iconWasCustomized: Bool? = nil
    }

    struct Pinned: Codable, Equatable {
        var id: UUID
        var url: URL
        var title: String
    }

    /// A browsing identity and its shared Favorites. Older profile records
    /// without these optional fields still restore their original stores.
    struct Profile: Codable, Equatable {
        /// The shape the earlier build encoded, kept exactly so its files
        /// still decode. `ephemeral` carried no identifier then.
        enum Kind: Codable, Equatable {
            case standard
            case isolated(UUID)
            case ephemeral
        }

        var id: UUID
        var name: String
        var kind: Kind
        var theme: String?
        var pinnedSites: [Pinned]? = nil
        var favoriteTabs: [Tab]? = nil
        var importedFavoriteIDs: [String]? = nil
        var preferences: ProfilePreferences? = nil
        var hasCustomName: Bool? = nil
    }

    var spaces: [Space]
    var activeSpaceIndex: Int
    /// Profiles retain their browsing identity and Favorites even with no Spaces.
    var profiles: [Profile]?
}

extension NSColor {
    /// `#rrggbb`, for storing a space tint in JSON. Falls back to the accent
    /// colour if the colour cannot be converted to sRGB.
    var hexString: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#007aff" }
        let components = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
        return "#" + components.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    convenience init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(
            srgbRed: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255,
            alpha: 1
        )
    }
}
