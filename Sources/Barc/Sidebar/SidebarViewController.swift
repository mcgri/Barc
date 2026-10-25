// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
// Modified for Barc: compact folder actions and icon picker, 2026-10-24.
import AppKit
import Combine

/// The vertical navigation surface: omnibox, the active space's tabs, and the
/// space switcher. Everything the user does to change context happens here.
@MainActor
final class SidebarViewController: NSViewController {
    private static let tabRowType = NSPasteboard.PasteboardType("io.github.mcgri.Barc.tabRow")
    private static let groupRowType = NSPasteboard.PasteboardType("io.github.mcgri.Barc.groupRow")

    private let session: BrowserSession
    private let diaHeader = SidebarHeaderView()
    private lazy var spaceIdentity = SidebarSpaceIdentityView(nameButton: diaHeader.spaceButton)
    private let browserControls = NSStackView()

    func installBrowserControls(_ controls: [NSView]) {
        _ = view
        browserControls.setViews(controls, in: .top)
        for control in controls {
            if let bar = control as? ContentTopBar { diaHeader.installNavigation(bar.takeNavigationRow()) }
            control.widthAnchor.constraint(equalTo: browserControls.widthAnchor).isActive = true
        }
    }

    /// Whether the header strip is the traffic lights' host at the moment.
    /// The window controller decides; compact mode and a trailing sidebar both
    /// put them somewhere else. See `SidebarHeaderView.hostsTrafficLights`.
    var headerHostsTrafficLights: Bool {
        get { wantsHeaderTrafficLights }
        set {
            wantsHeaderTrafficLights = newValue
            diaHeader.hostsTrafficLights = newValue && !isLibraryVisible
            if isLibraryVisible { library.header.hostsTrafficLights = newValue }
        }
    }
    private let pinnedTiles = PinnedTilesView()
    private let diaFooter = SidebarFooterView()
    private let nowPlayingView = SidebarNowPlayingView()
    /// The archive, shown in place of the pins and the tab list. Held rather
    /// than built on demand so its scroll position survives being left.
    private let archiveList = ArchiveListView()
    /// The footer's Archive button, so it can be shown as on while the archive
    /// is what the sidebar is displaying. Weak: the footer owns it, and rebuilds
    /// it whenever its actions are set.
    private weak var archiveButton: IconButton?
    private let tableView = SidebarTableView()
    private let scrollView = NSScrollView()
    private var spaceColorPopover: NSPopover?
    private var spaceIconPopover: NSPopover?
    private var normalStack: NSStackView?
    private var normalStackConstraints: [NSLayoutConstraint] = []
    private lazy var library = SidebarLibraryView(session: session)
    private(set) var isLibraryVisible = false
    private var wantsHeaderTrafficLights = true
    var onLibraryChange: ((Bool, LibraryCategory) -> Void)?
    var onLibraryOpen: ((LibraryEntry) -> Void)?

    /// Table view displaying tabs and groups.
    var tabListTableView: NSTableView { tableView }

    var onTabDragStateChange:((Bool) -> Void)?
    var onNewTab: (() -> Void)?
    var onChooseSplitPage: (() -> Void)?
    var onCustomizePage: ((Tab,String) -> Void)?

    /// Told which space is in front, so the window can wash the strip beside
    /// the page card with its colour and draw its border as well. The sidebar
    /// is the only thing watching the session for this, and duplicating that
    /// subscription in the window controller would give two places to keep
    /// in step.
    var onShownSpaceChange: ((Space, TimeInterval) -> Void)?
    /// The strip has been dragged part-way towards this neighbouring space.
    /// The page card's strip and the window's rim follow the sidebar.
    var onShownSpaceBlend: ((Space?, CGFloat) -> Void)?
    /// The wash changed without the space changing: the page in front has a
    /// colour of its own, or stopped having one.
    var onWashChange: ((NSColor?) -> Void)?
    /// The active space's gradient wash, for the page strip to match the
    /// sidebar. Nil when the space has a solid wash.
    var onGradientChange: ((WashGradient?) -> Void)?

    /// The space's colour washed over the sidebar's material. Created with the
    /// view, so it is only nil before `loadView`.
    private var tint: TintView?
    private var material: NSVisualEffectView?
    private let materialShade = ChromeMaterialShadeView()

    /// The space whose look the window should wear: the one in front, or
    /// the one being previewed by a drag.
    var shownSpaceForLook: Space { shownSpace }

    /// All tabs currently selected in the sidebar table view (multi-selection).
    var hasMultipleSelectedRows: Bool { tableView.selectedRowIndexes.count > 1 }

    var selectedTabs: [Tab] {
        var seen: Set<UUID> = []
        return tableView.selectedRowIndexes.flatMap { index -> [Tab] in
            guard rows.indices.contains(index) else { return [] }
            switch rows[index] {
            case .tab(let tab, _, _): return [tab]
            case .split(let split): return split.tabs
            default: return []
            }
        }.filter { seen.insert($0.id).inserted }
    }

    /// Stops the material showing the desktop through the window, for a
    /// space that wants full screen opaque. Blending within the window
    /// instead of behind it leaves the material on the window's own
    /// background, which is a plain colour.
    func setOpaque(_ opaque: Bool) {
        material?.blendingMode = opaque ? .withinWindow : .behindWindow
    }
    private var cancellables: Set<AnyCancellable> = []
    /// The sidebar list is no longer one row per tab: a collapsible group
    /// contributes a header row and, when open, its tabs. Flattening it once
    /// per reload keeps every index question -- selection, drag, refresh -- a
    /// lookup rather than a calculation.
    private var rows: [SidebarRow] = []
    /// The folder plate slices each row draws, rebuilt with `rows`.
    private var plates: [[FolderPlatePlan.Piece]] = []
    /// The same slices resolved with each group's colour and its place in the
    /// whole plate, so a themed group's gradient runs unbroken across its rows.
    private var slices: [[FolderPlateSlice]] = []
    /// Held while the group appearance editor is open, so it lives as long as
    /// the popover it drives.
    private var appearancePopover: NSPopover?
    private var folderIconPopover: NSPopover?
    private let settings = Settings.shared
    /// Advances the idle badges. Only the badges, and only the rows on screen;
    /// see `tickIdleBadges`.
    private var idleTimer: Timer?
    /// Once a second, so a badge counting seconds counts them. Above a minute
    /// the string stops changing on its own and the tick becomes a comparison
    /// that finds nothing, which is cheap enough to leave running rather than
    /// build a scheduler that would have to be re-armed on every scroll.
    private static let idleTickInterval: TimeInterval = 1

    /// One entry in the flattened sidebar list.
    ///
    /// New Tab is a row rather than a button in the header, which keeps the
    /// header to one label: the thing you are browsing as.
    private struct SidebarSplitRow {
        let id: UUID
        let anchor: Tab
        let tabs: [Tab]
        let depth: Int
        let isEscaping: Bool
    }

    private enum SidebarRow {
        case group(TabGroup, depth: Int, showsEscapedTab: Bool)
        case tab(Tab, depth: Int, isEscaping: Bool)
        case split(SidebarSplitRow)
        case liveStatus(TabGroup, LiveFolderStatus, depth: Int)
        case newTab

        /// What makes a row *the same row* across a rebuild.
        ///
        /// Deliberately only the thing the row stands for, and none of what it
        /// currently looks like: a tab that moved into a folder, changed depth,
        /// started loading or was renamed is still the same tab, and a list
        /// that treated it as a different one would animate it out and back in
        /// for a title change. Depth and state are content, and content is
        /// refreshed rather than animated.
        enum Identity: Hashable {
            case group(TabGroup.ID)
            case tab(Tab.ID)
            case split(UUID)
            case liveStatus(TabGroup.ID)
            case newTab
        }

        var identity: Identity {
            switch self {
            case .group(let group, _, _): .group(group.id)
            case .tab(let tab, _, _): .tab(tab.id)
            case .split(let split): .split(split.id)
            case .liveStatus(let group, _, _): .liveStatus(group.id)
            case .newTab: .newTab
            }
        }
    }

    /// Rows the next `viewFor` should spring into place rather than simply
    /// hand over.
    ///
    /// Keyed by identity rather than by row index because the table asks for
    /// its views part-way through applying the update, when an index means one
    /// thing before the batch and another after it.
    private var pendingEntrances: Set<SidebarRow.Identity> = []
    private var motionObservation: DisplayOptionsObservation?
    private var isRestoringDisplaySelection = false

    init(session: BrowserSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarViewController is created in code only")
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        wireActions()
        subscribeToSession()
        reloadSpaces()
        reloadTabs()
        reloadArchive()
        syncActiveTab()
        refreshNowPlaying()
        startIdleTicking()
    }

    private func startIdleTicking() {
        guard idleTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.idleTickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickIdleBadges() }
        }
        // A badge one second stale is not worth waking a sleeping Mac for, so
        // the tick is entirely tolerant and coalesces with whatever else the
        // run loop was going to do anyway.
        timer.tolerance = Self.idleTickInterval
        idleTimer = timer
    }

    // MARK: - Layout

    private func buildLayout() {
        configureTableView()

        // The sidebar supplies its own material now. A split item created with
        // sidebar behaviour would supply it, but it also draws a one-point
        // separator down its trailing edge that neither `dividerColor` nor a
        // zero `dividerThickness` removes -- measured. A plain item plus this
        // view is the same look without the rule.
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(material)
        self.material = material
        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: view.topAnchor),
            material.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            material.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // The profile's colour goes on above the material so the sidebar says
        // which identity is in front before a single word is read.
        materialShade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(materialShade)
        NSLayoutConstraint.activate([
            materialShade.topAnchor.constraint(equalTo: material.topAnchor),
            materialShade.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            materialShade.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            materialShade.trailingAnchor.constraint(equalTo: material.trailingAnchor)
        ])
        tint = TintView.install(over: materialShade, in: view)

        // Stands in for the titlebar the window does not have: drag to move,
        // double-click to zoom. It sits behind everything else in the strip so
        // the buttons in that area still receive their own clicks.
        let titlebar = TitlebarDragView()
        titlebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titlebar)
        NSLayoutConstraint.activate([
            titlebar.topAnchor.constraint(equalTo: view.topAnchor),
            titlebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titlebar.heightAnchor.constraint(equalToConstant: 34)
        ])

        diaHeader.spaceButton.menuProvider = { [weak self] in
            guard let self else { return nil }
            return makeSpaceOptionsMenu(for: shownSpace, anchor: spaceIdentity.moreButton)
        }
        diaHeader.spaceButton.setAccessibilityRole(.button)
        diaHeader.spaceButton.onPress = { [weak self] in
            guard let self else { return }
            let space = shownSpace
            var look = space.look
            look.pinnedSectionCollapsed.toggle()
            session.setLook(look, for: space)
        }

        pinnedTiles.onDismissHint = { [weak self] in
            guard let self else { return }
            let space = shownSpace
            session.dismissFavoritesHint(in:space)
        }
        pinnedTiles.dragItemProvider = { [weak self] id in
            guard let self,let target = favoriteTileTarget(id) else { return nil }
            let item = NSPasteboardItem()
            item.setString(target.site.id.uuidString,forType:SidebarTabDrag.favoriteType)
            item.setString(shownSpace.id.uuidString,forType:SidebarTabDrag.ownerType)
            item.setString(target.site.url.absoluteString,forType:.URL)
            return item
        }
        pinnedTiles.onDragStateChange = { [weak self] dragging in self?.onTabDragStateChange?(dragging) }
        pinnedTiles.canDropPayload = { [weak self] pasteboard,operation in self?.canDropOnFavorites(pasteboard,operation:operation) == true }
        pinnedTiles.onDropPayload = { [weak self] pasteboard,operation,index in self?.dropOnFavorites(pasteboard,operation:operation,index:index) == true }
        pinnedTiles.canDropTab = { [weak self] id in self?.canFavoriteTab(id: id) == true }
        pinnedTiles.onDropTab = { [weak self] id in
            guard let self, canFavoriteTab(id: id), let tab = session.activeSpace.tabs.first(where: { $0.id == id }) else { return false }
            session.pin(tab)
            return tab.pinnedSiteID != nil
        }
        pinnedTiles.onSelect = { [weak self] id in
            guard let self,let target = favoriteTileTarget(id) else { return }
            self.session.openPinnedSite(target.site)
        }
        pinnedTiles.onRemove = { [weak self] id in
            guard let self,let target = favoriteTileTarget(id) else { return }
            self.session.removePinnedSite(target.site)
        }
        pinnedTiles.onRename = { [weak self] id,anchor in
            guard let self,let target = favoriteTileTarget(id) else { return }
            let rect = pinnedTiles.convert(anchor.bounds,from:anchor)
            DispatchQueue.main.async { [weak self] in
                guard let self,pinnedTiles.window != nil,let current = favoriteTileTarget(id) else { return }
                let popover = NSPopover();popover.behavior = .transient
                popover.contentViewController = InlineNamePopover(name:current.site.title) { [weak self,weak profile = target.profile,weak popover] name in
                    if let self,let profile,let name { session.setFavoriteName(name,for:current.site.id,in:profile) }
                    popover?.close()
                }
                tabIconPopover?.close();tabIconPopover = popover
                popover.show(relativeTo:rect,of:pinnedTiles,preferredEdge:.minY)
            }
        }
        pinnedTiles.onChangeIcon = { [weak self] id,anchor in
            guard let self,let target = favoriteTileTarget(id) else { return }
            // Session updates replace individual tiles while the menu closes.
            // The strip survives those updates and keeps the same coordinates.
            let rect = pinnedTiles.convert(anchor.bounds,from:anchor)
            DispatchQueue.main.async { [weak self] in
                guard let self,pinnedTiles.window != nil,!pinnedTiles.isHiddenOrHasHiddenAncestor,
                      let current = favoriteTileTarget(id) else { return }
                showFavoriteIconPicker(for:current.site,in:target.profile,anchor:pinnedTiles,rect:rect)
            }
        }

        diaFooter.canDropOnSpace = { [weak self] id,board,operation in self?.canDropOnSpace(id,board:board,operation:operation) == true }
        diaFooter.onDropOnSpace = { [weak self] id,board,operation in self?.dropOnSpace(id,board:board,operation:operation) == true }
        diaFooter.onSelectSpace = { [weak self] id in
            guard let self, let space = self.session.spaces.first(where: { $0.id == id }) else { return }
            self.session.selectSpace(space)
        }
        diaFooter.onChangeIcon = { [weak self] id, choice in
            guard let self, let space = self.session.spaces.first(where: { $0.id == id }) else { return }
            self.session.setIcon(SpaceIcon(choice), for: space)
        }
        diaFooter.spaceMenuProvider = { [weak self] id, anchor in
            guard let self, let space = session.spaces.first(where: { $0.id == id }) else { return NSMenu() }
            return makeSpaceOptionsMenu(for: space, anchor: anchor)
        }
        diaFooter.addMenuProvider = { [weak self] in self?.makeAddMenu() ?? NSMenu() }
        diaFooter.onOpenLibrary = { [weak self] in self?.showLibrary() }
        // The icon dock switches spaces and configures their icons; everything
        // else about a space -- making, renaming, recolouring, deleting --
        // is the header menu's and Settings' job. The standing buttons are the
        // browser-wide lists that outlive any tab or space: Downloads for what
        // came out of the web, the Task Manager for what the browser is
        // costing right now, Archive for what left the sidebar. A foot-of-the-sidebar
        // affordance is where the eye looks for all three.
        //
        // The Archive button is always there, including when the archive is
        // empty and when archiving is switched off. A control that appears only
        // once the feature has taken something away is a control nobody finds
        // until they are already looking for a tab they have lost. It toggles
        // the sidebar into the archive and lights up while the archive is what
        // the sidebar is showing; the archive's own empty state explains
        // itself, and says where the setting is.
        rebuildFooterLeadingActions()
        diaFooter.setTrailingActions([
            TopBarAction(symbolName: "archivebox", label: "Archive") { [weak self] in
                self?.toggleArchive()
            }
        ])
        archiveButton = diaFooter.actionButton(labelled: "Archive") as? IconButton

        // The downloads list hangs off that button rather than opening a window
        // of its own, so the manager is told where to find it. A closure, not
        // the view: the footer rebuilds its buttons whenever its actions are
        // set, and the manager must not be left holding one that is gone.
        DownloadManager.shared.listAnchor = { [weak self] in
            self?.diaFooter.actionAnchor(labelled: "Downloads")
        }

        // The archive takes the pins' and the tab list's place in this stack
        // rather than sitting over it: the sidebar is one surface, and what it
        // is showing is what it draws.
        archiveList.isHidden = true
        archiveList.onRestore = { [weak self] record in self?.restoreFromArchive(record) }
        archiveList.onForget = { [weak self] record in self?.confirmForgetFromArchive(record) }
        archiveList.onClear = { [weak self] in self?.confirmClearArchive() }
        archiveList.onRestoreAll = { [weak self] in self?.restoreWholeArchive() }

        // Everything above the footer lives in one stack of its own, because a
        // space switch moves it as a unit. Transforming four sibling views in
        // step is four chances for them to drift apart, and AppKit will happily
        // recompute one of their opacities halfway through the animation.
        browserControls.orientation = .vertical
        browserControls.alignment = .leading
        browserControls.spacing = 6
        browserControls.translatesAutoresizingMaskIntoConstraints = false

        let identity = spaceIdentity
        let contentStack = NSStackView(views: [pinnedTiles, identity, scrollView, archiveList])
        contentStack.orientation = .vertical
        // The bands of the sidebar -- title, shortcuts, tabs -- are different
        // kinds of thing, so the space between them is the gutter rather than
        // the tighter rhythm the rows inside a band keep.
        contentStack.spacing = Style.Metrics.elementSeparation
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.wantsLayer = true
        switchingContent = contentStack

        nowPlayingView.isHidden = true
        nowPlayingView.onSelectTab = { [weak self] tab in
            guard let self else { return }
            if let space = self.session.spaces.first(where: { $0.tabs.contains(where: { $0.id == tab.id }) }) {
                if space.id != self.session.activeSpaceID {
                    self.session.selectSpace(space)
                }
                self.session.selectTab(tab)
            }
        }

        let stack = NSStackView(views: [diaHeader, browserControls, contentStack, nowPlayingView])
        stack.orientation = .vertical
        stack.spacing = Style.Metrics.elementSeparation
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(2.5, after: diaHeader)
        view.addSubview(stack)
        view.addSubview(diaFooter)
        normalStack = stack

        // The header owns the traffic-light strip, so the stack starts at the
        // very top of the sidebar rather than below a reserved band.
        normalStackConstraints = [
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            // The sidebar's content stops short of its trailing edge by the
            // same inset it starts from on the leading one. Without it the
            // pinned tiles and the tab pills run straight into the boundary
            // with the page, which reads as a crop rather than as a layout.
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Style.Metrics.sidebarInset
            ),
            stack.bottomAnchor.constraint(equalTo:diaFooter.topAnchor,constant:-Style.Metrics.elementSeparation),
            diaFooter.leadingAnchor.constraint(equalTo:view.leadingAnchor),
            diaFooter.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            diaFooter.bottomAnchor.constraint(equalTo:view.bottomAnchor),

            contentStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nowPlayingView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diaHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            browserControls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            archiveList.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            pinnedTiles.leadingAnchor.constraint(
                equalTo: contentStack.leadingAnchor,
                constant: Style.Metrics.sidebarInset
            ),
            pinnedTiles.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            identity.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            view.widthAnchor.constraint(
                // The split item's own minimum, not a second one derived from
                // the resting width. This constraint was the real floor: it held
                // the sidebar at 260 no matter what `minimumThickness` said.
                greaterThanOrEqualToConstant: Style.Metrics.sidebarMinWidth
            )
        ]
        NSLayoutConstraint.activate(normalStackConstraints)
    }

    var libraryCategory: LibraryCategory { library.category }

    func showLibrary(category: LibraryCategory? = nil) {
        _ = view
        folderNameEdit?.field.commit()
        if let category { library.select(category) }
        guard !isLibraryVisible else { onLibraryChange?(true, library.category); return }
        diaHeader.spaceButton.finishRenaming(commit: true)
        if isShowingArchive { setArchiveVisible(false) }
        library.onClose = { [weak self] in self?.hideLibrary() }
        library.onCategory = { [weak self] category in
            guard let self, isLibraryVisible else { return }
            onLibraryChange?(true, category)
        }
        library.onOpen = { [weak self] in self?.onLibraryOpen?($0) }
        isLibraryVisible = true
        diaHeader.hostsTrafficLights = false
        NSLayoutConstraint.deactivate(normalStackConstraints)
        normalStack?.removeFromSuperview()
        diaFooter.removeFromSuperview()
        view.addSubview(library)
        NSLayoutConstraint.activate([
            library.topAnchor.constraint(equalTo: view.topAnchor), library.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            library.leadingAnchor.constraint(equalTo: view.leadingAnchor), library.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        library.header.hostsTrafficLights = wantsHeaderTrafficLights
        library.setPresented(true)
        refreshWash()
        onLibraryChange?(true, library.category)
    }

    func hideLibrary() {
        guard isLibraryVisible else { return }
        library.header.hostsTrafficLights = false
        library.setPresented(false)
        library.removeFromSuperview()
        isLibraryVisible = false
        if let stack = normalStack {
            view.addSubview(stack);view.addSubview(diaFooter)
            NSLayoutConstraint.activate(normalStackConstraints)
        }
        diaHeader.hostsTrafficLights = wantsHeaderTrafficLights
        refreshWash()
        view.needsLayout = true
        onLibraryChange?(false, library.category)
    }

    func makeLibrarySpacesView() -> LibrarySpacesView {
        let overview = LibrarySpacesView(session: session)
        overview.menuProvider = { [weak self] space, anchor in self?.makeSpaceOptionsMenu(for: space, anchor: anchor) ?? NSMenu() }
        overview.onOpenTab = { [weak self] space, tab in
            guard let self else { return }; session.selectSpace(space); session.selectTab(tab); hideLibrary()
        }
        overview.onNewTab = { [weak self] space in
            guard let self else { return }; session.selectSpace(space); hideLibrary(); onNewTab?()
        }
        overview.onNewSpace = { [weak self] in self?.promptForNewSpace() }
        return overview
    }

    private func configureTableView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Style.Metrics.rowHeight
        // Rows carry their own margins in their height, and a folder's plate
        // is drawn in slices that have to meet edge to edge.
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        // The row draws its own pill, inset and rounded, which the table's own
        // highlight cannot be.
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        // A row's shadow is allowed to fall on its neighbours. The scroll view
        // still clips at the list's own edges, which is right.
        tableView.clipsToBounds = false
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(activateTabRow(_:))
        // Resolve the event's row without AppKit's square contextual highlight.
        tableView.menuForRow = { [weak self] row in self?.makeRowMenu(at: row) ?? NSMenu() }
        // The space around the list keeps the generic sidebar menu.
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        view.menu = menu
        // Rows from this list, and addresses from anywhere: a link dragged
        // off a page or out of the address bar becomes a tab where it lands.
        tableView.registerForDraggedTypes([SidebarTabDrag.favoriteType, SidebarTabDrag.type, Self.tabRowType, Self.groupRowType, .URL])
        tableView.setDraggingSourceOperationMask([.copy,.move], forLocal: true)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.positionFolderNameEditor(); self?.positionTabNameEditor() }
            }.store(in: &cancellables)
    }

    private func wireActions() {
    }

    // MARK: - Session updates

    private func subscribeToSession() {
        session.changes
            .sink { [weak self] change in
                guard let self else { return }
                switch change {
                case .spaces:
                    self.reloadSpaces()
                    self.reloadTabs()
                    self.reloadArchive()
                    self.refreshNowPlaying()
                case .tabs:
                    self.reloadTabs()
                    self.refreshArchiveBadge()
                    self.refreshNowPlaying()
                case .activeTab:
                    self.syncActiveTab()
                    self.refreshWash()
                    self.refreshNowPlaying()
                case .tab(let tab):
                    self.refreshRow(for: tab)
                    if tab.id == self.shownSpace.activeTab?.id { self.refreshWash() }
                    self.refreshNowPlaying()
                case .structure:
                    self.reloadTabs()
                    // Archiving, putting back, forgetting and a space's own
                    // groups all arrive as structure; only the archive cares
                    // which of them it was.
                    self.reloadArchive()
                    self.refreshNowPlaying()
                case .bookmarks:
                    break
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: .tabMediaStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNowPlaying()
            }
        }

        motionObservation = DisplayOptionsObservation { [weak self] in
            guard let self, self.reducesMotion else { return }
            self.applyRestImmediately()
            self.pendingEntrances = []
            let scroll = self.tableView.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin
            let selection = self.tableView.selectedRowIndexes
            self.isRestoringDisplaySelection = true
            self.tableView.reloadData()
            self.tableView.selectRowIndexes(selection, byExtendingSelection: false)
            self.isRestoringDisplaySelection = false
            self.refreshSelectionAppearance()
            if let scroll, let origin {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            self.positionFolderNameEditor()
            self.positionTabNameEditor()
        }

        // The footer's Task Manager button, switched on or off in Settings
        // while the window is open.
        NotificationCenter.default.addObserver(
            forName: .taskManagerButtonDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildFooterLeadingActions()
            }
        }

        // A new density means new row heights, so every row is rebuilt.
        NotificationCenter.default.addObserver(
            forName: .sidebarDensityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tableView.rowHeight = Style.Metrics.rowHeight
                self.reloadTabs()
            }
        }
    }

    /// The buttons in the footer's leading corner.
    ///
    /// Rebuilt rather than hidden, because the footer owns its buttons and
    /// hands them out fresh whenever its actions are set -- and because the
    /// Task Manager one is optional, so what is down there depends on a
    /// setting that can change while the window is open.
    private func rebuildFooterLeadingActions() {
        var actions = [
            TopBarAction(symbolName: "arrow.down.circle", label: "Downloads") {
                DownloadManager.shared.showList()
            }
        ]
        // The Task Manager sits beside Downloads rather than opposite Archive
        // because it belongs to the same family: a browser-wide window that is
        // about the browser, not about this space. It opens the same one as
        // Shift-Command-U -- the gauge is for the people who never learn the
        // shortcut, which is most people, and "why is the fan on" is a question
        // you ask while looking at the window.
        if settings.showsTaskManagerInSidebar {
            actions.append(
                TopBarAction(symbolName: "speedometer", label: "Task Manager") { [weak self] in
                    guard let self else { return }
                    TaskManagerWindowController.show(session: self.session)
                }
            )
        }
        diaFooter.setLeadingActions(actions)
    }

    private func findActiveMediaTab() -> Tab? {
        let all = session.allTabs
        return all.first(where: { $0.id == session.activeTab?.id && ($0.isPlayingMedia || $0.isPlayingAudio) })
            ?? all.first(where: { $0.isPlayingMedia || $0.isPlayingAudio })
            ?? all.first(where: { $0.isInPictureInPicture })
    }

    private func refreshNowPlaying() {
        nowPlayingView.update(with: findActiveMediaTab())
    }

    // MARK: - Switching animation

    /// Everything above the footer, as one view.
    ///
    /// The footer stays put on purpose. Its dots are the indicator for the
    /// switch, and an indicator that slides away with the thing it is indexing
    /// tells the user nothing during the one moment they need it.
    private var switchingContent: NSView?

    /// The outgoing space, held on screen while it travels out.
    private var outgoingStill: SpaceStillView?

    /// The neighbouring space, shown beside the live content while the fingers
    /// are down. The strip is a filmstrip from the first point of the drag:
    /// the space being pulled in is already visible, sliding in as the current
    /// one slides away. Without it the drag shows one space moving into empty
    /// material and the other appearing only after the release, which is what
    /// "it just suddenly came" described.
    private var neighbourStill: SpaceStillView?
    /// Which way `neighbourStill` is previewing: +1 for the next space.
    private var neighbourOffset = 0

    /// The space the sidebar is drawing instead of the active one, for the one
    /// moment the neighbour is photographed. Nil almost always.
    private var previewSpace: Space?

    /// A switch is animating, so the content is meant to be away from rest.
    private var isSwitching = false

    /// A switch is animating. A drag that started now would fight it.
    var isSwitchInFlight: Bool { isSwitching || isLibraryVisible }

    /// The space the sidebar is currently drawing.
    private var shownSpace: Space { previewSpace ?? session.activeSpace }

    /// When the fingers last moved the content. A drag that never gets its end
    /// event -- a gesture claimed twice, a tracking loop that stops early --
    /// would otherwise leave the sidebar parked half off the screen with no way
    /// back, which is a far worse failure than a swipe that does nothing.
    private var lastDragTime: TimeInterval = 0

    /// Fires if a drag stops arriving without ever ending.
    private var dragWatchdog: DispatchWorkItem?

    /// Reduce Motion is a request not to slide things across the screen. The
    /// switch still happens; it just arrives rather than travels.
    private var reducesMotion: Bool {
        Style.Motion.isReduced
    }

    /// A switch from rest -- a click on a dot -- takes about a
    /// quarter of a second. A release after a drag takes only the remaining
    /// distance's share of that, with a floor so a release from nearly there
    /// still reads as movement rather than a cut. The release from most of the
    /// way across lands in four or five frames.
    static let switchDuration: TimeInterval = 0.25
    static let minimumSwitchDuration: TimeInterval = 0.08

    /// Live feedback while the fingers are still down.
    ///
    /// No fading. Content keeps full opacity all the way through a switch; a
    /// swipe is a move, not a dissolve. What does change with the drag is the
    /// colour: the wash moves from this profile's colour towards the
    /// neighbour's as the neighbour comes in.
    func applySwipe(translation: CGFloat, crossfade: CGFloat) {
        guard !reducesMotion else { applyRestImmediately();return }
        guard let content = switchingContent else { return }
        lastDragTime = ProcessInfo.processInfo.systemUptime
        content.wantsLayer = true
        content.layer?.removeAnimation(forKey: Self.slideKey)
        content.layer?.setAffineTransform(CGAffineTransform(translationX: translation, y: 0))

        // Content moving towards the leading edge is the next space coming in
        // from the trailing one.
        let direction = translation < 0 ? 1 : (translation > 0 ? -1 : 0)
        if direction != neighbourOffset {
            discardNeighbourStill()
            if direction != 0 {
                neighbourStill = makeNeighbourStill(offset: direction)
                neighbourOffset = neighbourStill == nil ? 0 : direction
            }
        }
        let width = max(view.bounds.width, 1)
        neighbourStill?.offsetX = translation + width * CGFloat(direction)
        let neighbour = neighbourSpace(offset: direction)
        tint?.blend(toward: neighbour?.wash(for: neighbour?.activeTab), fraction: crossfade)
        onShownSpaceBlend?(neighbour, crossfade)

        // A reload is not guaranteed to follow, and a sidebar parked half off
        // the screen with nothing coming to put it back is the worst state this
        // can end in. So the drag also watches itself.
        dragWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in self?.abandonStalledDrag() }
        dragWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: watchdog)
    }

    /// The fingers stopped moving the content and no end ever arrived. Put it
    /// back rather than leaving it where it stopped.
    private func abandonStalledDrag() {
        guard !isSwitching, outgoingStill == nil, let content = switchingContent,
              let layer = content.layer, layer.animation(forKey: Self.slideKey) == nil,
              layer.affineTransform().tx != 0
        else { return }
        springBack(content, from: layer.affineTransform().tx)
        lastDragTime = 0
    }

    /// Back to rest from a drag that is not going to switch, with the colour
    /// following the content home.
    private func springBack(_ content: NSView, from tx: CGFloat) {
        let width = max(view.bounds.width, 1)
        let duration = Self.releaseDuration(remaining: abs(tx), width: width)
        slide(content, fromX: tx, toX: 0, duration: duration)
        if let still = neighbourStill {
            slide(still, fromX: still.offsetX, toX: width * CGFloat(neighbourOffset), duration: duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, neighbourStill === still else { return }
                discardNeighbourStill()
            }
        }
        tint?.show(shownSpace.wash(for: shownSpace.activeTab), animatedOver: duration)
        syncSidebarGradient(shownSpace, animatedOver: duration)
        onShownSpaceChange?(shownSpace, duration)
    }

    /// Sets the sidebar tint's gradient to a space's, fading it over the same
    /// time the wash takes. The page strip follows through `onGradientChange`
    /// and `onShownSpaceChange`.
    private func syncSidebarGradient(_ space: Space, animatedOver duration: TimeInterval) {
        guard let tint else { return }
        tint.transitionDuration = duration
        tint.gradientWash = space.washGradient(for: space.activeTab)
        tint.grainAmount = isLibraryVisible ? 0 : space.chromeGrain
        tint.transitionDuration = 0
    }

    /// How long the rest of a switch takes: the full duration for the full
    /// width, proportionally less for what is left after a drag.
    static func releaseDuration(remaining: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return minimumSwitchDuration }
        let share = max(0, min(1, remaining / width))
        return max(minimumSwitchDuration, switchDuration * share)
    }

    /// The swipe was abandoned, or it ran off the end of the row. Spring back
    /// to where it started.
    func cancelSwipe() {
        guard !reducesMotion else { applyRestImmediately();return }
        guard let content = switchingContent else { return }
        lastDragTime = 0
        dragWatchdog?.cancel()
        dragWatchdog = nil
        discardStill()
        springBack(content, from: content.layer?.affineTransform().tx ?? 0)
    }

    /// Runs the carousel: the outgoing space leaves by one edge while the
    /// incoming one arrives from the other, both at full opacity and both on
    /// screen at once.
    ///
    /// The sidebar has only one header, one tile strip and one tab list, so the
    /// space that is leaving has to be a photograph of itself. `dataWithPDF`
    /// takes it. The two obvious alternatives do not:
    /// `cacheDisplay(in:to:)` returns only what already sits in a layer's
    /// contents, which loses every pill, and `CALayer.render(in:)` returns
    /// nothing at all.
    ///
    /// - Parameter offset: which way the switch is going. +1 is forward, which
    ///   sends the outgoing space out by the leading edge.
    func animateSwitch(offset: Int, changeSpace: @escaping () -> Void) {
        guard !reducesMotion, let content = switchingContent else {
            changeSpace()
            applyRestImmediately()
            return
        }
        let width = max(view.bounds.width, 1)
        let step = width * CGFloat(offset)
        // Where the drag left the content; 0 for a switch from a click.
        let start = content.layer?.affineTransform().tx ?? 0
        isSwitching = true
        lastDragTime = 0
        dragWatchdog?.cancel()
        dragWatchdog = nil

        // Photographed before the space changes, and left exactly where the
        // live content was -- including however far the fingers had dragged it.
        discardStill()
        let still = makeStill(of: content)
        outgoingStill = still
        // The live content takes over from the preview at the same spot, and
        // the two are the same drawing, so the swap is not visible.
        discardNeighbourStill()

        // The strip is contiguous: the incoming space sits exactly one width
        // beyond the outgoing one, wherever the outgoing one is. Starting it
        // from the far edge instead left a gap the size of the drag, which is
        // what made it arrive suddenly.
        let incomingStart = start + step
        let duration = Self.releaseDuration(remaining: abs(incomingStart), width: width)

        tint?.transitionDuration = duration
        themeTransitionDuration = duration
        changeSpace()
        tint?.transitionDuration = 0
        themeTransitionDuration = 0
        // The new content has to be laid out before it is moved, or it arrives
        // and then jumps as the table resolves its rows.
        view.layoutSubtreeIfNeeded()

        slide(content, fromX: incomingStart, toX: 0, duration: duration)
        if let still {
            still.offsetX = start
            slide(still, fromX: start, toX: start - incomingStart, duration: duration)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            guard let self, outgoingStill === still else { return }
            isSwitching = false
            discardStill()
        }
    }

    /// How long the page card is given to follow a theme change. Non-zero only
    /// for the duration of `changeSpace()` inside a switch.
    private var themeTransitionDuration: TimeInterval = 0

    /// A photograph of the space one step away, taken by drawing it into the
    /// sidebar for an instant and drawing the active space back before
    /// anything reaches the screen. Both reloads happen inside one turn of the
    /// run loop, so the window is never flushed showing the wrong space.
    private func makeNeighbourStill(offset: Int) -> SpaceStillView? {
        guard let content = switchingContent, let space = neighbourSpace(offset: offset) else { return nil }
        previewSpace = space
        reloadSpaces()
        reloadTabs()
        view.layoutSubtreeIfNeeded()
        let still = makeStill(of: content)
        previewSpace = nil
        reloadSpaces()
        reloadTabs()
        view.layoutSubtreeIfNeeded()
        return still
    }

    private func neighbourSpace(offset: Int) -> Space? {
        let spaces = session.sidebarSpaces
        guard offset != 0,
              let index = spaces.firstIndex(where: { $0.id == session.activeSpaceID }),
              spaces.indices.contains(index + offset)
        else { return nil }
        return spaces[index + offset]
    }

    private func discardNeighbourStill() {
        neighbourStill?.removeFromSuperview()
        neighbourStill = nil
        neighbourOffset = 0
    }

    /// Nothing may leave the sidebar parked off to one side.
    ///
    /// Called from every reload, which is the one thing guaranteed to happen
    /// after any switch. A drag that is still live is left alone; one that has
    /// not moved for half a second has lost its end event and is abandoned.
    private func ensureContentAtRest() {
        if reducesMotion { applyRestImmediately();return }
        guard !isSwitching, outgoingStill == nil, let content = switchingContent,
              let layer = content.layer, layer.animation(forKey: Self.slideKey) == nil,
              layer.affineTransform().tx != 0
        else { return }

        let sinceDrag = ProcessInfo.processInfo.systemUptime - lastDragTime
        guard lastDragTime == 0 || sinceDrag > 0.5 else { return }
        applyRestImmediately()
    }

    /// A copy of the live content, laid over it at rest.
    ///
    /// `convert` ignores the live content's layer transform, so the still
    /// lands where the content would be at rest however far it has been
    /// dragged; the caller sets `offsetX` to put it where it belongs.
    private func makeStill(of source: NSView) -> SpaceStillView? {
        let bounds = source.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        // Via PDF, which is the printing path and calls `draw(_:)` on every view
        // in the tree rather than reading back what a layer happens to hold.
        guard let image = NSImage(data: source.dataWithPDF(inside: bounds)) else { return nil }
        image.size = bounds.size

        let still = SpaceStillView(image: image, restFrame: source.convert(bounds, to: view))
        view.addSubview(still)
        return still
    }

    private func discardStill() {
        outgoingStill?.removeFromSuperview()
        outgoingStill = nil
    }

    /// Moves the live content sideways, explicitly.
    ///
    /// `NSAnimationContext` with `allowsImplicitAnimation` does not do this.
    /// AppKit turns implicit animation off on a layer-backed view's layer, so a
    /// transform assigned inside an animation group snaps to its final value.
    private func slide(_ view: NSView, fromX: CGFloat, toX: CGFloat, duration: TimeInterval) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: Self.slideKey)

        // The model value first: an animation only covers the journey, and
        // whatever is set here is where the view stays afterwards.
        layer.setAffineTransform(CGAffineTransform(translationX: toX, y: 0))

        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = CATransform3DMakeTranslation(fromX, 0, 0)
        move.toValue = CATransform3DMakeTranslation(toX, 0, 0)
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(move, forKey: Self.slideKey)
    }

    /// Moves a still sideways. The still is positioned by its frame, so the
    /// journey is on the layer's position rather than a transform.
    private func slide(_ still: SpaceStillView, fromX: CGFloat, toX: CGFloat, duration: TimeInterval) {
        still.offsetX = toX
        guard let layer = still.layer else { return }
        layer.removeAnimation(forKey: Self.slideKey)

        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = layer.position.x - (toX - fromX)
        move.toValue = layer.position.x
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(move, forKey: Self.slideKey)
    }

    private static let slideKey = "barc.slide"

    private func applyRestImmediately() {
        isSwitching = false
        lastDragTime = 0
        dragWatchdog?.cancel();dragWatchdog = nil
        discardStill()
        discardNeighbourStill()
        guard let content = switchingContent else { return }
        content.layer?.removeAnimation(forKey: Self.slideKey)
        content.layer?.setAffineTransform(.identity)
        content.alphaValue = 1
        tint?.show(shownSpace.wash(for: shownSpace.activeTab), animatedOver: 0)
        syncSidebarGradient(shownSpace, animatedOver: 0)
        onShownSpaceChange?(shownSpace, 0)
    }

    private func reloadSpaces() {
        // Everything outside the sliding content is left alone while the
        // neighbour is being photographed: the dots, the menu and the colour
        // belong to the space that is actually active.
        if previewSpace == nil {
            ensureContentAtRest()
            diaFooter.showSpaces(session.sidebarSpaces.map {
                SpaceDockItem(id: $0.id, name: $0.name, icon: $0.icon, color: $0.sidebarIconColor)
            }, selectedID: session.activeSpaceID)
        }
        // One label, one concept: the space is the identity.
        let space = shownSpace
        diaHeader.spaceButton.isSectionCollapsed = space.look.pinnedSectionCollapsed
        diaHeader.spaceButton.setAccessibilityExpanded(!space.look.pinnedSectionCollapsed)
        applyChromeAppearance(for: space)
        diaHeader.spaceButton.show(
            title: space.name,
            // Only what the user put there. The dot is not repeated in the
            // header: the window is already washed in the space's colour, and
            // a dot beside the name would be saying it a second time.
            icon: space.icon.isCustomized
                ? space.icon.image(
                    color: space.sidebarIconColor,
                    title: space.name,
                    side: MenuLabelButton.iconSide
                )
                : nil,
            accessibilityLabel: "Space",
            tooltip: space.isPrivate
                ? "\(space.name). Private: nothing is written to disk."
                : "\(space.name). Profile: \(space.profile.name).",
            identity: space.id
        )
        if previewSpace == nil {
            tint?.wash = space.wash(for: space.activeTab)
            syncSidebarGradient(space, animatedOver: themeTransitionDuration)
            onShownSpaceChange?(space, themeTransitionDuration)
        }
        refreshPinnedTiles()
    }

    private func applyChromeAppearance(for space: Space) {
        materialShade.isHidden = space.activeImportedChrome?.usesLightMaterial != true
        materialShade.strength = isLibraryVisible ? LibraryMetrics.materialStrength : 0.21
        if let chrome = space.activeImportedChrome {
            view.appearance = space.look.appearance == .system
                ? NSAppearance(named: chrome.usesDarkText ? .aqua : .darkAqua) : space.look.appearance.appearance
            material?.appearance = NSAppearance(named: chrome.usesLightMaterial ? .aqua : .darkAqua)
        } else if space.theme == .custom, space.look.appearance == .system,
           let rgb = space.color.usingColorSpace(.sRGB) {
            let brightness = rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114
            view.appearance = NSAppearance(named: brightness > 0.53 ? .aqua : .darkAqua)
            material?.appearance = NSAppearance(named: .darkAqua)
        } else {
            view.appearance = space.look.appearance.appearance
            material?.appearance = nil
        }
    }

    /// Rebuilt whenever the space or the visible page changes, because which
    /// tile is active depends on both.
    private func refreshPinnedTiles() {
        let space = shownSpace
        let activeID = space.activeTab?.id
        pinnedTiles.dropColor = space.color
        pinnedTiles.show(
            space.pinnedSites.map { site in
                PinnedTile(
                    id: space.id.uuidString+"/"+space.profile.id.uuidString+"/"+site.id.uuidString,
                    title: site.title,
                    url: site.url,
                    // The tab the shortcut owns, not a URL comparison: the
                    // site navigates away from the pinned address immediately
                    // and the tile would stop recognising its own page.
                    isActive: activeID != nil && space.activeTab?.pinnedSiteID == site.id,
                    favicon: space.tab(forPin: site.id)?.restoredFavicon,icon:site.icon
                )
            },
            isPrivate: space.isPrivate,
            showsEmptyHint: !space.favoritesHintDismissed
        )
    }

    private func favoriteDrag(in pasteboard:NSPasteboard) -> (Space,PinnedSite)? {
        guard let items = pasteboard.pasteboardItems,items.count == 1,
              let raw = items[0].string(forType:SidebarTabDrag.favoriteType),let id = UUID(uuidString:raw),
              let owner = items[0].string(forType:SidebarTabDrag.ownerType),let ownerID = UUID(uuidString:owner),
              let source = session.spaces.first(where:{ $0.id == ownerID }),
              let site = source.pinnedSites.first(where:{ $0.id == id }) else { return nil }
        return (source,site)
    }

    private func workspaceDrag(in pasteboard:NSPasteboard) -> (Space,[Tab])? {
        guard let items = pasteboard.pasteboardItems,!items.isEmpty else { return nil }
        let owners = Set(items.compactMap { $0.string(forType:SidebarTabDrag.ownerType) })
        guard owners.count == 1,let raw = owners.first,let id = UUID(uuidString:raw),
              let source = session.spaces.first(where:{ $0.id == id }) else { return nil }
        var tabs:[Tab] = [],seen:Set<UUID> = []
        for item in items {
            guard let raw = item.string(forType:SidebarTabDrag.type),let id = UUID(uuidString:raw),
                  let tab = source.workspaceTabs.first(where:{ $0.id == id }) else { return nil }
            if seen.insert(id).inserted { tabs.append(tab) }
        }
        return (source,tabs)
    }

    private func canDropOnFavorites(_ pasteboard:NSPasteboard,operation:NSDragOperation) -> Bool {
        guard shownSpace === session.activeSpace,previewSpace == nil else { return false }
        if let (source,site) = favoriteDrag(in:pasteboard) {
            if source.profile === shownSpace.profile { return operation == .move }
            return shownSpace.pinnedSites.count<12 && (site.split != nil || !shownSpace.pinnedSites.contains(where:{ $0.matches(site.url) }))
                && source.profile.favoriteTabs.filter { $0.pinnedSiteID == site.id }.allSatisfy { !$0.isLocked }
                && site.split?.members.allSatisfy { $0.page.isLocked != true } != false
                && session.canReceiveFavorite(site.id,from:source,into:shownSpace,copy:operation == .copy)
        }
        guard let (source,tabs) = workspaceDrag(in:pasteboard) else { return false }
        return session.canFavoriteSidebarTabs(tabs,from:source,into:shownSpace)
    }

    private func dropOnFavorites(_ pasteboard:NSPasteboard,operation:NSDragOperation,index:Int) -> Bool {
        guard canDropOnFavorites(pasteboard,operation:operation) else { return false }
        if let (source,site) = favoriteDrag(in:pasteboard) {
            if source.profile === shownSpace.profile {
                guard let old = shownSpace.pinnedSites.firstIndex(where:{ $0.id == site.id }) else { return false }
                session.movePinnedSite(from:old,to:index);return true
            }
            return session.changes.batch {
                let pages = session.receiveFavorite(site.id,from:source,into:shownSpace,copy:operation == .copy)
                guard let first = pages.first else { return false }
                session.pin(first)
                guard let id = first.pinnedSiteID,let old = shownSpace.pinnedSites.firstIndex(where:{ $0.id == id }) else { return false }
                session.movePinnedSite(from:old,to:index);return true
            }
        }
        guard let (source,tabs) = workspaceDrag(in:pasteboard) else { return false }
        return session.favoriteSidebarTabs(tabs,from:source,into:shownSpace,copy:operation == .copy,at:index)
    }

    private func canDropOnSpace(_ id:UUID,board:NSPasteboard,operation:NSDragOperation) -> Bool {
        guard let target = session.spaces.first(where:{ $0.id == id }) else { return false }
        if let (source,site) = favoriteDrag(in:board) {
            return session.canReceiveFavorite(site.id,from:source,into:target,copy:operation == .copy)
        }
        guard let (source,tabs) = workspaceDrag(in:board) else { return false }
        let ids = Set(tabs.flatMap { source.splits.layout(containing:$0.id)?.tabIDs ?? [$0.id] })
        return ids.allSatisfy { id in source.workspaceTabs.first(where:{ $0.id == id }).map { !$0.isLocked && !session.isInLiveFolder($0) } == true }
    }

    private func dropOnSpace(_ id:UUID,board:NSPasteboard,operation:NSDragOperation) -> Bool {
        guard canDropOnSpace(id,board:board,operation:operation),let target = session.spaces.first(where:{ $0.id == id }) else { return false }
        return session.changes.batch {
            session.selectSpace(target)
            let pages:[Tab]
            if let (source,site) = favoriteDrag(in:board) {
                pages = session.receiveFavorite(site.id,from:source,into:target,copy:operation == .copy)
                guard !pages.isEmpty,session.moveSidebarTabs(pages,to:target.tabs.count,group:nil,before:nil,retained:false) else { return false }
            } else if let (source,tabs) = workspaceDrag(in:board) {
                if source === target {
                    guard let first = tabs.first else { return false }
                    if operation == .copy {
                        return session.duplicateSidebarTabs(tabs,to:target.tabs.count,group:nil,before:nil,retained:first.isSidebarRetained)
                    }
                    let selected = source.splits.preferredTab(containing:first.id).flatMap { id in source.tabs.first { $0.id == id } } ?? first
                    session.selectTab(selected);return true
                }
                pages = session.receiveSidebarTabs(tabs,from:source,into:target,copy:operation == .copy)
            } else { return false }
            guard let first = pages.first else { return false }
            let selected = target.splits.preferredTab(containing:first.id).flatMap { id in target.tabs.first { $0.id == id } } ?? first
            session.selectTab(selected);return true
        }
    }

    private func favoriteTileTarget(_ id:String) -> (profile:BrowserProfile,site:PinnedSite)? {
        let parts = id.split(separator:"/")
        guard parts.count == 3,previewSpace == nil,shownSpace === session.activeSpace,
              parts[0] == shownSpace.id.uuidString,parts[1] == shownSpace.profile.id.uuidString,
              let site = shownSpace.pinnedSites.first(where:{ $0.id.uuidString == parts[2] }) else { return nil }
        return (shownSpace.profile,site)
    }

    private func showFavoriteIconPicker(for site:PinnedSite,in profile:BrowserProfile,anchor:NSView,rect:NSRect? = nil) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = CompactSpaceIconPicker(selected:site.icon,label:"Favorite icon") {
            [weak self,weak profile,weak popover] icon in
            guard let self,let profile else { return }
            session.setFavoriteIcon(icon,for:site.id,in:profile)
            popover?.close()
        }
        tabIconPopover?.close();tabIconPopover = popover
        popover.show(relativeTo:rect ?? anchor.bounds,of:anchor,preferredEdge:.minY)
    }

    private func canFavoriteTab(id: UUID) -> Bool {
        guard previewSpace == nil, shownSpace === session.activeSpace,
              session.activeSpace.pinnedSites.count < 12,
              let tab = session.activeSpace.tabs.first(where: { $0.id == id }),
              !StartPage.isStartPage(tab.url), session.canFavorite(tab) else { return false }
        return true
    }
    func makeSpaceOptionsMenu(for space: Space, anchor: NSView) -> NSMenu {
        let hasGitHub = space.groups.contains { group in
            guard let source = session.liveFolders.record(for: group.id)?.source else { return false }
            if case .github = source { return true }
            return false
        }
        return SpaceOptionsMenu.make(canDelete: session.spaces.count > 1, hasGitHubFolder: hasGitHub,
                                     profiles: session.profiles, selectedProfileID: space.profile.id, allowsProfileChange: !space.isPrivate,
                                     isVisibleInDock:space.look.showsInDock,
                                     canHideFromDock:session.spaces.contains { $0 !== space && $0.look.showsInDock },
                                     exportSource: space, exportDestinations: session.spaces) {
            [weak self, weak space, weak anchor] action in
            guard let self, let space, session.spaces.contains(where: { $0 === space }) else { return }
            if isLibraryVisible, [.rename, .newFolder, .github].contains(action) { hideLibrary() }
            // The Space being acted on comes from the menu, even when its dock
            // icon was right-clicked while a different Space was in front.
            if [.rename, .newFolder, .github, .theme].contains(action) { session.selectSpace(space) }
            DispatchQueue.main.async { [weak self, weak space, weak anchor] in
                guard let self, let space, session.spaces.contains(where: { $0 === space }) else { return }
                switch action {
                case .profile(let id):
                    if let profile = session.profiles.first(where: { $0.id == id }) { session.assignProfile(profile, to: space) }
                case .newProfile:
                    let alert = NSAlert()
                    alert.messageText = "New Profile"
                    alert.informativeText = "Profiles keep logins, history and Favorites separate."
                    let name = NSTextField(string: "New Profile"); name.placeholderString = "Profile name"
                    name.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
                    alert.accessoryView = name
                    alert.addButton(withTitle: "Create Profile"); alert.addButton(withTitle: "Cancel")
                    alert.window.initialFirstResponder = name
                    guard alert.runModal() == .alertFirstButtonReturn,
                          let profile = session.addProfile(named: name.stringValue) else { return }
                    session.assignProfile(profile, to: space)
                case .rename:
                    diaHeader.spaceButton.beginRenaming { [weak self, weak space] name in
                        guard let self, let space, session.spaces.contains(where: { $0 === space }) else { return }
                        session.rename(space, to: name)
                    }
                case .icon:
                    showSpaceIconPicker(for: space, anchor: anchor ?? spaceIdentity.moreButton)
                case .theme: showSpaceColorEditor(for: space, anchor: anchor ?? spaceIdentity.moreButton)
                case .exportInto(let id):
                    guard let target = session.spaces.first(where: { $0.id == id }) else { return }
                    do {
                        if try session.exportSpace(space, intoFolderIn: target) != nil { session.selectSpace(target) }
                    } catch {
                        if let window = view.window { NSAlert(error: error).beginSheetModal(for: window) }
                    }
                case .newFolder: newGroupFromMenu()
                case .github: newGitHubGroup(scope: .pullRequests)
                case .manage: showSpaceSettings()
                case .toggleDock: session.setDockVisible(!space.look.showsInDock,for:space)
                case .delete:
                    guard session.spaces.count > 1 else { return }
                    confirm(message: "Delete the Space \u{201c}\(space.name)\u{201d}?",
                            detail: space.isPrivate ? "Its tabs will be closed." : "Its tabs will be closed. Its profile, Favorites and saved browsing data will be kept.",
                            action: "Delete") { [weak self, weak space] in
                        guard let self, let space else { return }
                        session.removeSpace(space)
                    }
                }
            }
        }
    }

    private func showSpaceIconPicker(for space: Space, anchor: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = CompactSpaceIconPicker(selected: space.icon) { [weak self, weak space, weak popover] icon in
            guard let self, let space, session.spaces.contains(where: { $0 === space }) else { return }
            session.setIcon(icon, for: space)
            popover?.close()
        }
        spaceIconPopover?.close()
        spaceIconPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func showSpaceColorEditor(for space: Space, anchor: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = SidebarThemeEditor(session: session, space: space)
        spaceColorPopover?.close()
        spaceColorPopover = popover
        let position = anchor.convert(anchor.bounds, to: view)
        let trailing = settings.sidebarPosition == .trailing
        let halfHeight = (popover.contentViewController?.preferredContentSize.height ?? 508) / 2
        let y = min(view.bounds.maxY - 1, max(position.midY, view.bounds.minY + halfHeight + 52))
        popover.show(relativeTo: NSRect(x: trailing ? view.bounds.minX : view.bounds.maxX - 1, y: y, width: 1, height: 1),
                     of: view, preferredEdge: trailing ? .minX : .maxX)
    }

    /// Recomputed on every rebuild; cheap, tens of tabs.
    private var duplicateIDs: Set<Tab.ID> = []

    /// The space the rows on screen belong to, so the next rebuild can tell a
    /// list that changed from a different list altogether.
    private var shownRowsSpaceID: Space.ID?
    private var folderNameEdit: (id: UUID, space: Space, group: TabGroup, field: FolderNameEditor)?
    private var tabNameEdit: (id: UUID, space: Space, tab: Tab, splitID:UUID?, field: FolderNameEditor)?
    private(set) var tabIconPopover: NSPopover?

    private func reloadTabs() {
        tableView.showSplitDropPreview(nil)
        if let edit = tabNameEdit,
           shownSpace !== edit.space || !edit.space.tabs.contains(where: { $0 === edit.tab })
                || edit.splitID.map { edit.space.splits.identifier(containing:edit.tab.id) != $0 } == true {
            edit.field.commit()
        }
        if let edit = folderNameEdit,
           shownSpace !== edit.space || edit.space.group(withID: edit.group.id) !== edit.group {
            edit.field.commit()
        }
        duplicateIDs = session.duplicateTabIDs(in: shownSpace)
        if previewSpace == nil { ensureContentAtRest() }

        // Row animations are only meaningful *within* one space's list. Moving
        // to another space does not close ten tabs and open eight others -- it
        // shows a different list, which happens to be made of rows too, and
        // animating that produces exactly the churn it looks like: every row
        // sliding out while unrelated ones slide in.
        //
        // It also has to be instant rather than merely tidy. Switching spaces
        // photographs the neighbouring space by drawing it into the sidebar and
        // drawing the real one back before the window is flushed, twice in one
        // turn of the run loop (`makeNeighbourStill`). An animation started
        // there outlives the turn it was started in, so it is still running --
        // and visible -- long after the frame it was supposed to be invisible
        // for. The still-image crossfade is the space switch's animation, and
        // it is the only one it should have.
        let sameSpace = shownRowsSpaceID == shownSpace.id
        shownRowsSpaceID = shownSpace.id

        let before = rows.map(\.identity)
        rebuildRows()

        if sameSpace {
            applyRowChanges(from: before, to: rows.map(\.identity))
        } else {
            pendingEntrances = []
            tableView.reloadData()
        }
        syncActiveTab()
        positionFolderNameEditor()
        positionTabNameEditor()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionFolderNameEditor()
        positionTabNameEditor()
    }

    /// Hands the rebuild to the table as the change it actually was.
    ///
    /// `reloadData` is correct and was what this did, but it throws every row
    /// away and builds them again, so opening a tab and closing one look
    /// exactly alike: the list simply is different now. Telling the table which
    /// rows arrived and which left instead lets it open and close the gaps
    /// itself, and gives the arriving row something to spring out of.
    ///
    /// It falls back to `reloadData` whenever the change is not expressible as
    /// insertions and removals -- a reorder, or the first fill -- because a
    /// table told a half-truth about its own contents raises rather than
    /// misdraws, and a dragged tab is a reorder.
    private func applyRowChanges(from before: [SidebarRow.Identity], to after: [SidebarRow.Identity]) {
        pendingEntrances = []
        guard !reducesMotion else { tableView.reloadData();return }

        let removed: IndexSet
        let inserted: IndexSet
        switch RowChangePlan.change(from: before, to: after) {
        case .reload:
            tableView.reloadData()
            return
        case .contentOnly:
            // Nothing came or went, so nothing should move. A plain reload is
            // what this has always done and is still the right answer: the
            // rows are in their places and only what is drawn inside them has
            // changed, so there is no animation to preserve by being cleverer.
            tableView.reloadData()
            return
        case .edits(let removals, let insertions):
            removed = removals
            inserted = insertions
        }

        pendingEntrances = Set(inserted.map { after[$0] })

        tableView.beginUpdates()
        // Leaving is a collapse and a fade, which is AppKit's own and is
        // already the right shape: the gap the row occupied closes behind it.
        tableView.removeRows(at: removed, withAnimation: [.effectFade, .slideUp])
        // Arriving is a fade while the gap opens; the travel is added by the
        // cell itself, in `viewFor`, because only a spring can overshoot and
        // `NSTableView.AnimationOptions` has no spring in it.
        tableView.insertRows(at: inserted, withAnimation: .effectFade)
        tableView.endUpdates()

        refreshRows(excluding: inserted)
    }

    /// Brings the rows that kept their views across the update back up to date.
    ///
    /// Those views can be stale in two ways that matter: a tab's own content
    /// may have changed in the same breath, and -- more easily missed -- a row
    /// that did not itself change can still need redrawing because its
    /// *neighbour* did. A folder plate's rounded bottom belongs to whichever
    /// row is currently last inside it, so closing a tab hands that corner to
    /// the row above.
    ///
    /// The rows that were just inserted are excluded by index rather than by
    /// consulting `pendingEntrances`, which by now is empty: the table asks for
    /// their views during `endUpdates`, and each ask takes its row out of that
    /// set. Reloading them here would hand them a second, fresh view and throw
    /// away the entrance the first one was in the middle of.
    private func refreshRows(excluding inserted: IndexSet) {
        let kept = IndexSet(integersIn: rows.indices).subtracting(inserted)
        guard !kept.isEmpty else { return }
        tableView.reloadData(forRowIndexes: kept, columnIndexes: IndexSet(integer: 0))
        // The plates live on the row view rather than the cell, so reloading
        // the cells does not reach them.
        tableView.enumerateAvailableRowViews { [weak self] rowView, index in
            guard let self, let plate = rowView as? FolderPlateRowView else { return }
            plate.slices = self.slices.indices.contains(index) ? self.slices[index] : []
        }
        tableView.noteHeightOfRows(withIndexesChanged: kept)
    }

    /// Groups first, each followed by its tabs when open, then everything that
    /// belongs to no group. Order inside a group is the Space's own tab order,
    /// so grouping never reorders anything.
    private func rebuildRows() {
        let space = shownSpace
        var flattened: [SidebarRow] = []
        let kept = space.sidebarVisibleTabs.filter { $0.groupID == nil && $0.keepsInSidebar }
        let remaining = space.sidebarVisibleTabs.filter { $0.groupID != nil || !$0.keepsInSidebar }
        for row in FolderRowPlan.rows(
            groups: space.groups,
            // A pinned shortcut is represented by its tile; listing its tab as
            // well shows the same site twice.
            tabs: kept + remaining,
            activeTabID: space.splits.layout(containing: space.activeTabID)?.tabIDs.first ?? space.activeTabID
        ) {
            switch row {
            case .folder(let group, let depth, let showsEscapedTab):
                flattened.append(.group(group, depth: depth, showsEscapedTab: showsEscapedTab))
                // A live folder with nothing to show says which kind of nothing.
                if group.isLive, !group.isCollapsed {
                    let count = space.tabs(in: group).count
                    let status = session.liveFolders.status(for: group.id, itemCount: count)
                    if status != .ready {
                        flattened.append(.liveStatus(group, status, depth: depth + 1))
                    }
                }
            case .tab(let tab, let depth, let isEscaping):
                flattened.append(.tab(tab, depth: depth, isEscaping: isEscaping))
            }
        }
        let visibleIDs = Set(flattened.compactMap { row -> UUID? in
            if case .tab(let tab, _, _) = row { return tab.id }; return nil
        })
        var anchors: [UUID: UUID] = [:]
        for layout in space.splits.layouts {
            guard let first = layout.tabIDs.first, let id = space.splits.identifier(containing: first) else { continue }
            anchors[id] = layout.tabIDs.first(where: visibleIDs.contains)
        }
        flattened = flattened.compactMap { row in
            guard case .tab(let tab, let depth, let escaping) = row,
                  let layout = space.splits.layout(containing: tab.id),
                  let id = space.splits.identifier(containing: tab.id) else { return row }
            guard anchors[id] == tab.id else { return nil }
            let members = layout.tabIDs.compactMap { member in space.tabs.first { $0.id == member } }
            return .split(SidebarSplitRow(id: id, anchor: tab, tabs: members, depth: depth, isEscaping: escaping))
        }
        var firstOrdinaryTab = flattened.firstIndex {
            switch $0 {
            case .tab(let tab, let depth, _): return depth == 0 && !tab.keepsInSidebar
            case .split(let split): return split.depth == 0 && !split.anchor.keepsInSidebar
            default: return false
            }
        } ?? flattened.count
        if space.look.pinnedSectionCollapsed {
            flattened.removeFirst(firstOrdinaryTab)
            firstOrdinaryTab = 0
        }
        flattened.insert(.newTab, at: firstOrdinaryTab)
        rows = flattened
        plates = FolderPlatePlan.pieces(for: dropRows)
        slices = buildSlices()
    }

    /// Resolves each plate slice with its group's colour and its band in the
    /// whole plate. The geometry needs row heights, which is why it lives here
    /// rather than in the pure `FolderPlatePlan`.
    private func buildSlices() -> [[FolderPlateSlice]] {
        let gap = Style.Metrics.folderPlateGap
        let appearances = Dictionary(
            shownSpace.groups.map { ($0.id, $0.appearance) },
            uniquingKeysWith: { first, _ in first }
        )

        // The rows each group's plate covers, header first, and the top offset
        // and full height each of those rows needs for a continuous fill.
        var geometry: [TabGroup.ID: [Int: (plateTop: CGFloat, plateHeight: CGFloat)]] = [:]
        var rowsOf: [TabGroup.ID: [Int]] = [:]
        for (index, pieces) in plates.enumerated() {
            for piece in pieces {
                guard let id = piece.groupID else { continue }
                rowsOf[id, default: []].append(index)
            }
        }
        for (id, indices) in rowsOf {
            let heights = indices.map { tableView(tableView, heightOfRow: $0) }
            let below = indices.last.map { plateGapBelow(row: $0) } ?? 0
            let placed = FolderPlateGeometry.slices(rowHeights: heights, gap: gap, gapBelow: below)
            var map: [Int: (plateTop: CGFloat, plateHeight: CGFloat)] = [:]
            for (offset, index) in indices.enumerated() where placed.indices.contains(offset) {
                map[index] = placed[offset]
            }
            geometry[id] = map
        }

        return plates.enumerated().map { index, pieces in
            pieces.map { piece in
                let appearance = piece.groupID.flatMap { appearances[$0] } ?? .standard
                let place = piece.groupID.flatMap { geometry[$0]?[index] }
                return FolderPlateSlice(
                    segment: piece.segment,
                    depth: piece.depth,
                    appearance: appearance,
                    plateTop: place?.plateTop ?? 0,
                    plateHeight: place?.plateHeight ?? 0,
                    // Only the slice that closes the plate carries the space
                    // under it; the rows above it are plate top to bottom.
                    gapBelow: piece.segment == .bottom || piece.segment == .single
                        ? plateGapBelow(row: index)
                        : 0
                )
            }
        }
    }

    private func row(of tab: Tab) -> Int? {
        rows.firstIndex {
            switch $0 {
            case .tab(let candidate, _, _): return candidate.id == tab.id
            case .split(let split): return split.tabs.contains { $0 === tab }
            default: return false
            }
        }
    }

    private func syncActiveTab() {
        let space = shownSpace
        if let tab = space.activeTab, let index = row(of: tab) {
            if !tableView.selectedRowIndexes.contains(index) {
                tableView.selectRowIndexes([index], byExtendingSelection: false)
            }
            // Selection can move from a keyboard shortcut or a menu item, which
            // is no help if the row is scrolled out of sight.
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
        // Rows draw their own selection, so every visible one has to be told.
        for index in rows.indices {
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TabRowView
            cell?.isSelected = tableView.selectedRowIndexes.contains(index)
            if case .split(let split) = rows[index],
               let cell = tableView.view(atColumn: 0,row: index,makeIfNecessary:false) as? SplitRowView {
                configure(cell, with: split)
                cell.isSelected = tableView.selectedRowIndexes.contains(index)
            }
        }
        // Which tile is active depends on the visible page, so it moves with it.
        refreshPinnedTiles()
    }

    /// The wash can change without the space changing: a page in front
    /// declared a colour, or a different tab came to the front.
    private func refreshWash() {
        guard previewSpace == nil else { return }
        let space = shownSpace
        let wash = space.wash(for: space.activeTab)
        let gradient = space.washGradient(for: space.activeTab)
        applyChromeAppearance(for: space)
        tint?.grainAmount = isLibraryVisible ? 0 : space.chromeGrain
        guard tint?.wash != wash || tint?.gradientWash != gradient else { return }
        tint?.wash = wash
        tint?.gradientWash = gradient
        onWashChange?(wash)
        onGradientChange?(gradient)
    }

    private func refreshRow(for tab: Tab) {
        guard let index = row(of: tab), let cell = tableView.view(atColumn: 0,row:index,makeIfNecessary:false) else { return }
        if case .split(let split) = rows[index], let cell = cell as? SplitRowView {
            configure(cell,with:split)
        } else if let cell = cell as? TabRowView { configure(cell,with:tab,depth:depth(ofRow:index)) }
    }

    /// How long a tab has been idle, as the badge shows it, or `nil` when there
    /// is nothing worth showing.
    ///
    /// A tab that is on screen never carries one, whatever the setting says.
    /// `lastActiveAt` is stamped when a tab becomes visible and not again while
    /// it stays there, so the tab being read right now would otherwise wear a
    /// timer counting how long it has been read -- true of the clock, and a lie
    /// about what the badge means.
    private func idleText(for tab: Tab) -> String? {
        // A tab that reloads itself says so in the badge's place; so does one
        // that another tab duplicates.
        if tab.autoReloadInterval != nil { return "↻" }
        if duplicateIDs.contains(tab.id) { return "⧉" }
        guard settings.tabIdleBadgeMode.showsBadge(isAsleep: tab.isAsleep),
              !session.visibleTabIDs.contains(tab.id)
        else { return nil }
        return TabIdleLabel.text(for: tab.idleDuration())
    }

    private func idleSpoken(for tab: Tab) -> String? {
        if tab.autoReloadInterval != nil { return "reloads automatically" }
        if duplicateIDs.contains(tab.id) { return "another tab shows the same page" }
        guard idleText(for: tab) != nil else { return nil }
        return TabIdleLabel.spoken(for: tab.idleDuration())
    }

    /// Re-reads the timer on every row on screen.
    ///
    /// Only the badge, and only where the string actually changed: the rows
    /// themselves are untouched, so this cannot disturb a favicon, a selection
    /// or a row the user is dragging.
    private func tickIdleBadges() {
        guard settings.tabIdleBadgeMode != .never else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for index in visible.lowerBound..<visible.upperBound {
            guard rows.indices.contains(index), case .tab(let tab, _, _) = rows[index],
                  let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TabRowView
            else { continue }
            cell.updateIdle(text: idleText(for: tab), spoken: idleSpoken(for: tab))
        }
    }

    /// The nesting level a row is drawn at, or 0 for anything that is not a tab.
    private func depth(ofRow index: Int) -> Int {
        guard rows.indices.contains(index), case .tab(_, let depth, _) = rows[index] else { return 0 }
        return depth
    }

    /// The one place a `Tab` becomes the plain values a `TabRowView` takes.
    private func configure(_ cell: TabRowView, with tab: Tab, depth: Int) {
        let owner = shownSpace
        cell.onRename = { [weak self,weak owner,weak tab] in
            guard let self,let owner,let tab,!isLibraryVisible,previewSpace == nil,
                  shownSpace === owner,session.activeSpace === owner,
                  session.spaces.contains(where:{ $0 === owner }),owner.tabs.contains(where:{ $0 === tab }) else { return }
            beginNamingTab(tab,in:owner)
        }
        // The same leading inset the group headers use, so a tab that belongs
        // to no folder lines up with a top-level folder rather than sitting
        // four points further out and running its pill into the sidebar edge.
        cell.isEditingName = tabNameEdit?.tab === tab
        cell.indentation = Style.Metrics.sidebarInset + FolderTree.indent(forDepth: depth)
        cell.configure(rowContent(for: tab))
        cell.onToggleMute = { [weak tab] in
            tab?.toggleMute()
        }
        cell.onResetPinnedPage = { [weak self, weak tab] keepCurrent in
            guard let self, let tab else { return false }
            return self.session.resetSidebarPin(tab, keepingCurrentPage: keepCurrent)
        }
        // `tab.url` deliberately, not `displayURL`: the latter follows a typed
        // address before it commits, which would swap one site's icon for
        // another's mid-keystroke.
        cell.favicon.show(for: tab.url, in: tab.currentWebView, isPrivate: tab.isPrivate, restored: tab.restoredFavicon)
        cell.onClose = { [weak self] in
            guard let self else { return }
            guard !tab.isLocked else { return session.reportCloseRefused(tab) }
            guard TabClosing.confirm(closing: tab) else { return }
            session.closeTab(tab)
        }
    }

    private func rowContent(for tab: Tab) -> TabRowContent {
        TabRowContent(
            title: tab.displayTitle,
            address: tab.note.map { "\(tab.url.absoluteString)\n\($0)" } ?? tab.url.absoluteString,
            subtitle: SidebarLocalAddress.label(for: tab.url),
            isLoading: tab.isLoading,
            isAsleep: tab.isAsleep,
            isFailed: tab.failure != nil,
            idleText: idleText(for: tab),
            idleSpoken: idleSpoken(for: tab),
            keepsAwake: tab.keepsAwake,
            keepsInSidebar: tab.keepsInSidebar,
            isLocked: tab.isLocked,
            isPlayingAudio: tab.isPlayingAudio,
            isMuted: tab.isMuted,
            colorTag: tab.colorTag,
            hasUnreadChange: tab.hasUnreadChange && !session.visibleTabIDs.contains(tab.id),
            emoji: tab.emoji,
            sidebarSymbolName: tab.sidebarSymbolName,
            canResetPinnedPage: session.canResetSidebarPin(tab)
        )
    }

    private func configure(_ cell: SplitRowView, with split: SidebarSplitRow) {
        let space = shownSpace
        let focused = space.splits.preferredTab(containing: split.anchor.id)
        cell.indentation = Style.Metrics.sidebarInset + FolderTree.indent(forDepth: split.depth)
        cell.configure(split.tabs.map { rowContent(for: $0) }, focusedIndex: split.tabs.firstIndex { $0.id == focused },
                       name:space.splits.name(containing:split.anchor.id),icon:space.splits.icon(containing:split.anchor.id))
        cell.isEditingName = tabNameEdit?.splitID == split.id
        cell.onRename = { [weak self,weak space] in
            guard let self,let space,shownSpace === space,space.splits.identifier(containing:split.anchor.id) == split.id else { return }
            beginNamingTab(split.anchor,in:space)
        }
        cell.onCloseUnit = { [weak self,weak space] in
            guard let self,let space,shownSpace === space,space.splits.identifier(containing:split.anchor.id) == split.id,
                  split.tabs.allSatisfy({ !$0.isLocked }) else { return }
            session.closeTabs(split.tabs)
        }
        for (index,tab) in split.tabs.enumerated() {
            cell.members[index].favicon.show(for:tab.url,in:tab.currentWebView,isPrivate:tab.isPrivate,restored:tab.restoredFavicon)
            cell.members[index].title.alphaValue = tabNameEdit?.tab === tab ? 0 : 1
        }
        cell.onSelectMember = { [weak self, weak space] index in
            guard let self, let space, split.tabs.indices.contains(index), self.shownSpace === space,
                  space.splits.identifier(containing: split.tabs[index].id) == split.id else { return }
            self.session.selectTab(split.tabs[index])
        }
        cell.onCloseMember = { [weak self, weak space] index in
            guard let self, let space, split.tabs.indices.contains(index), self.shownSpace === space else { return }
            let tab = split.tabs[index]
            guard space.splits.identifier(containing:tab.id) == split.id else { return }
            guard !tab.isLocked else { self.session.reportCloseRefused(tab); return }
            guard TabClosing.confirm(closing:tab) else { return }
            self.session.closeTab(tab)
        }
        cell.onResetMember = { [weak self, weak space] index,keep in
            guard let self, let space, self.shownSpace === space, split.tabs.indices.contains(index),
                  space.splits.identifier(containing:split.tabs[index].id) == split.id else { return false }
            return self.session.resetSidebarPin(split.tabs[index],keepingCurrentPage:keep)
        }
    }

    // MARK: - Archive

    /// Whether the sidebar is showing the archive instead of a space's tabs.
    private(set) var isShowingArchive = false

    /// Shows or hides the archive in place of the pins and the tab list.
    ///
    /// A mode rather than a window. The archive holds the rows that left the
    /// sidebar, so the place they left from is the place to look for them. The
    /// space's own list is kept up to date while the archive is in front of it,
    /// which is what makes leaving the mode instant, and what makes a tab put
    /// back land somewhere the user can see.
    func setArchiveVisible(_ visible: Bool) {
        guard visible != isShowingArchive else { return }
        isShowingArchive = visible
        pinnedTiles.isHidden = visible
        scrollView.isHidden = visible
        archiveList.isHidden = !visible
        archiveButton?.isActive = visible
        diaFooter.isShowingArchive = visible
        if visible { reloadArchive() }
    }

    func toggleArchive() { setArchiveVisible(!isShowingArchive) }

    @objc private func toggleArchiveFromMenu() { toggleArchive() }

    /// The archive of the space the sidebar is showing, newest first -- the
    /// order someone hunting for "the thing that just vanished" reads in.
    ///
    /// One space at a time, because that is what an archive in a sidebar means.
    /// A tab left a space's list; the place to look for it is the foot of that
    /// same list, and a Work tab showing up under Personal is the archive
    /// answering a question nobody asked. Switching space switches the archive
    /// with it, which is why a space change reloads this.
    ///
    /// The rows carry no space name for the same reason: every one of them is
    /// from the space whose sidebar they are being shown in.
    private func reloadArchive() {
        archiveList.show(
            session.archivedTabs(in: shownSpace)
                .map { ArchiveListView.Entry(record: $0, spaceName: nil) },
            isArchivingEnabled: settings.tabArchiveDelay != nil
        )
        refreshArchiveBadge()
    }

    /// The count on the footer's Archive button.
    ///
    /// The button carries it whether or not the archive is open: an archive is
    /// a drawer things disappear into, and the point of a number on the outside
    /// of a drawer is that you can see there is something in it without opening
    /// it.
    ///
    /// Separate from `reloadArchive` because it is also wanted on a plain tab
    /// change: putting one back through the toast's Undo arrives as `.tabs`,
    /// and the badge would otherwise sit there still counting a tab that is
    /// back in the sidebar.
    ///
    /// It counts this space's archive only, so it agrees with the list the
    /// button opens. A badge counting every space would send someone into an
    /// archive that turns out to be empty.
    private func refreshArchiveBadge() {
        archiveButton?.badgeCount = session.archivedTabs(in: shownSpace).count
    }

    /// Puts one back and goes to it: restoring a tab is an act of wanting to
    /// read the page. The list stays in the archive, so several can be put back
    /// without leaving the mode and coming back to it.
    private func restoreFromArchive(_ record: BrowserSession.ArchivedTab) {
        session.restoreArchived(record)
        reloadArchive()
    }

    /// Puts this space's whole archive back, and leaves the archive: the list
    /// is empty now, and staying in an empty list to look at the sentence about
    /// sleeping tabs is not what someone who just asked for all of them back
    /// wants to see. The sidebar they are dropped back into is.
    ///
    /// No confirmation. Everything here can be archived again -- by hand from a
    /// row's menu, or by the sweep that put it here in the first place -- which
    /// is exactly what `confirmClearArchive` asks about and this does not have
    /// to.
    private func restoreWholeArchive() {
        guard !session.restoreAllArchived(in: shownSpace).isEmpty else { return }
        setArchiveVisible(false)
    }

    /// Asks first. The archive is itself the undo for everything else, so
    /// forgetting is the one thing here that cannot be taken back.
    private func confirmForgetFromArchive(_ record: BrowserSession.ArchivedTab) {
        confirm(
            message: "Remove \u{201c}\(record.title)\u{201d} from the archive?",
            detail: "It will not come back. Put it back in the sidebar instead if you still want it.",
            action: "Remove"
        ) { [weak self] in
            self?.session.forgetArchived(record)
        }
    }

    private func confirmClearArchive() {
        let space = shownSpace
        let count = session.archivedTabs(in: space).count
        guard count > 0 else { return }
        // Named, because Clear under a list that shows one space's archive must
        // not read as though it empties the browser's.
        confirm(
            message: "Remove \(count) archived tab\(count == 1 ? "" : "s") from \(space.name)?",
            detail: "This clears this Space's archive. Other Spaces keep theirs. They will not come back.",
            action: "Remove"
        ) { [weak self] in
            self?.session.clearArchive(in: space)
        }
    }

    /// A confirmation, as a sheet when there is a window to hang it on and as a
    /// plain alert when there is not -- the same reading the group and space
    /// questions use.
    private func confirm(
        message: String,
        detail: String,
        action: String,
        then commit: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { commit() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            commit()
        }
    }

    // MARK: - Actions

    @objc private func newTab() {
        onNewTab?()
    }

    @objc private func goBack() { session.activeTab?.goBack() }
    @objc private func goForward() { session.activeTab?.goForward() }
    /// One control, two jobs: stop while loading, reload otherwise.
    @objc private func reload() {
        guard let tab = session.activeTab else { return }
        if tab.isLoading {
            tab.stopLoading()
        } else {
            tab.reload()
        }
    }

    /// The responder chain does not reach the app delegate from a menu built
    /// here, so the target is named rather than left to `nil`.
    @objc private func showSpaceSettings() {
        NSApp.sendAction(#selector(AppDelegate.showSpaceSettings(_:)), to: NSApp.delegate, from: nil)
    }

    @objc private func chooseSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? Space else { return }
        session.selectSpace(space)
    }

    @objc private func newSpaceFromMenu() { promptForNewSpace() }
    @objc private func newPrivateSpaceFromMenu() { promptForNewPrivateSpace() }

    private func promptForNewSpace() { presentNewSpaceSheet(initialPrivate: false) }
    private func promptForNewPrivateSpace() { presentNewSpaceSheet(initialPrivate: true) }

    /// The sheet that names a space and picks its colour -- solid or a gradient
    /// with a direction -- in one step, so a space is its colour from the moment
    /// it is made.
    private func presentNewSpaceSheet(initialPrivate: Bool, movingFolder: TabGroup? = nil, movingTab: Tab? = nil) {
        let sheet = NewSpaceSheet(
            suggestedColor: session.nextUnusedTheme().color,
            initialPrivate: initialPrivate
        ) { [weak self] options in
            guard let self else { return }
            let folderSpace = movingFolder.flatMap { folder in session.spaces.first { $0.group(withID: folder.id) === folder } }
            if movingFolder != nil, folderSpace == nil { return }
            let tabSpace = movingTab.flatMap { session.sidebarOwner(of: $0) }
            if movingTab != nil, tabSpace == nil { return }
            let space = session.addSpace(
                named: options.name,
                isPrivate: options.isPrivate,
                icon: options.icon,
                profile: options.isPrivate ? nil : (folderSpace?.profile ?? tabSpace?.profile ?? (session.activeSpace.isPrivate ? session.profiles.first { $0.identity == .standard } : session.activeSpace.profile))
            )
            if options.keepsItsOwnColour {
                switch options.wash {
                case .solid(let colour):
                    session.setCustomColor(colour, for: space)
                case .gradient(let gradient):
                    session.setSpaceGradient(gradient, for: space)
                }
            } else {
                // A plain window, or one the page colours: the space carries no
                // colour of its own. Exactly what the Spaces pane does when you
                // choose anything but Customized.
                session.setTheme(.neutral, for: space)
            }
            // The rest of the sheet, applied in one go: appearance, how
            // strongly the colour washes, and whether the bookmarks bar shows.
            // The colour above went through the session's own setters because
            // each clears the other's fill; these are plain fields of the look.
            session.setLook(options.look(from: space.look), for: space)
            if let movingFolder { session.move(movingFolder, toSpace: space) }
            if let movingTab { session.move(movingTab, toSpace: space) }
        }
        presentAsSheet(sheet)
    }

    // MARK: - Context menu

    func makeAddMenu() -> NSMenu {
        let menu = NSMenu(title: "Add")
        let space = NSMenuItem(title: "New Space", action: #selector(newSpaceFromMenu), keyEquivalent: "")
        space.target = self
        menu.addItem(space)
        let folder = NSMenuItem(title: "New Folder", action: #selector(newGroupFromMenu), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "New Boost", action: #selector(BrowserWindowController.openBoostEditorFromMenu(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "New Split", action: #selector(BrowserWindowController.splitSideBySide(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t"))
        for item in menu.items where item.action != nil && item.target == nil {
            item.target = view.window?.windowController
        }
        return menu
    }

    /// Blank sidebar space and New Tab use the same compact Space menu.
    func makeContextMenu(anchor: NSView? = nil) -> NSMenu {
        makeSpaceOptionsMenu(for: shownSpace, anchor: anchor ?? view)
    }

    /// Compact tab actions retain the clicked owner even if the active Space changes.
    func makeTabMenu(for tab: Tab, anchor: NSView? = nil) -> NSMenu {
        let owner = session.sidebarOwner(of: tab)
        let retained = tab.isSidebarRetained
        let customizeHost = session.customizablePageHost(for:tab)
        let addingSplit = owner?.activeTab === tab
        let canSplit: Bool
        if let owner, let current = owner.activeTab {
            if addingSplit {
                canSplit = owner.splits.layout(containing:current.id)?.isFull != true
            } else {
                // Plan with complete groups, just as the eventual join does.
                // A single active page can instead open a transient empty pane.
                var proposed = owner.splits
                canSplit = proposed.join([current.id,tab.id],grid:.sideBySide)
            }
        } else { canSplit = false }
        let canArchive: (BrowserSession.SidebarArchiveScope) -> Bool = { [session] scope in
            owner.map { !session.sidebarArchiveCandidates(relativeTo: tab, in: $0, scope: scope).isEmpty } ?? false
        }
        return TabOptionsMenu.make(retained: retained, muted: tab.isMuted, canMute: tab.isPlayingAudio || tab.isMuted,
            canRemove: retained ? !tab.isLocked : canArchive(.tab), canSplit: canSplit, addingSplit: addingSplit,
            canReplacePinnedURL: (tab.pinnedPageURL ?? tab.url) != tab.url,
            canCustomize:customizeHost != nil,
            owner: owner, destinations: session.sidebarSpaces, canArchiveOther: canArchive(.other),
            canArchiveAbove: canArchive(.above), canArchiveBelow: canArchive(.below)) {
            [weak self, weak tab, weak owner, weak anchor] action in
            guard let self, let tab, let owner, session.spaces.contains(where: { $0 === owner }),
                  owner.tabs.contains(where: { $0 === tab }) else { return }
            DispatchQueue.main.async { [weak self, weak tab, weak owner, weak anchor] in
                guard let self, let tab, let owner, session.spaces.contains(where: { $0 === owner }),
                      owner.tabs.contains(where: { $0 === tab }) else { return }
                switch action {
                case .copyLink:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
                case .icon: showTabIconPicker(for: tab, in: owner, anchor: anchor)
                case .rename: beginNamingTab(tab, in: owner)
                case .mute: if tab.isPlayingAudio || tab.isMuted { tab.toggleMute() }
                case .customize:
                    guard let customizeHost,session.customizablePageHost(for:tab) == customizeHost else { return }
                    onCustomizePage?(tab,customizeHost)
                case .split: session.selectSpace(owner); splitTab(tab)
                case .duplicate: session.selectSpace(owner); session.duplicate(tab)
                case .move(let id):
                    guard let destination = session.spaces.first(where: { $0.id == id }) else { return }
                    session.move(tab, toSpace: destination)
                case .newSpace:
                    presentNewSpaceSheet(initialPrivate: owner.isPrivate, movingTab: tab)
                case .archive: session.archiveSidebarTabs(relativeTo: tab, in: owner, scope: .tab)
                case .archiveOther: session.archiveSidebarTabs(relativeTo: tab, in: owner, scope: .other)
                case .archiveAbove: session.archiveSidebarTabs(relativeTo: tab, in: owner, scope: .above)
                case .archiveBelow: session.archiveSidebarTabs(relativeTo: tab, in: owner, scope: .below)
                case .removePin: session.removeSidebarPin(tab, in: owner)
                case .replacePinnedURL: if tab.isSidebarRetained { tab.setPinnedPageURL(tab.url) }
                case .editPinnedURL: editPinnedPage(for: tab, in: owner)
                }
            }
        }
    }

    private func showTabIconPicker(for tab: Tab, in owner: Space, anchor: NSView?) {
        if let id = tab.pinnedSiteID,let site = owner.pinnedSites.first(where:{ $0.id == id }) {
            showFavoriteIconPicker(for:site,in:owner.profile,anchor:anchor ?? tableView)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = CompactSpaceIconPicker(selected: tab.sidebarIcon) { [weak self, weak owner, weak tab, weak popover] icon in
            guard let self, let owner, let tab, session.spaces.contains(where: { $0 === owner }),
                  owner.tabs.contains(where: { $0 === tab }) else { return }
            tab.setSidebarIcon(icon)
            popover?.close()
        }
        let origin = anchor ?? tableView
        tabIconPopover?.close(); tabIconPopover = popover
        popover.show(relativeTo: origin.bounds, of: origin, preferredEdge: .minY)
    }

    private func editPinnedPage(for tab: Tab, in owner: Space) {
        guard tab.isSidebarRetained else { return }
        PinnedPageEditor(url: tab.pinnedPageURL ?? tab.url) { [weak self, weak tab, weak owner] url in
            guard let self, let tab, let owner, session.spaces.contains(where: { $0 === owner }),
                  owner.tabs.contains(where: { $0 === tab }), tab.isSidebarRetained else { return }
            tab.setPinnedPageURL(url)
        }.present(in: view.window)
    }

    /// Older lifecycle and annotation tools stay available by holding Option.
    func makeExtendedTabMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        let space = session.sidebarOwner(of: tab) ?? session.activeSpace
        func add(_ title: String, _ selector: Selector, symbol: String? = nil, key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.representedObject = tab
            item.isEnabled = enabled
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        menu.autoenablesItems = false

        add("Pin", #selector(pinTabFromMenu(_:)), symbol: "pin", enabled: !session.isPinned(tab))
        menu.addItem(.separator())

        // The two locks and the two manual actions, in one block: they are the
        // whole of what a user can say about this tab's lifecycle, and finding
        // half of them here and half in Settings is how a feature becomes
        // folklore. Each lock reads as what it will do next, not as its state.
        add(tab.keepsAwake ? "Allow Sleeping" : "Keep Awake",
            #selector(toggleKeepAwakeFromMenu(_:)),
            symbol: tab.keepsAwake ? "moon" : "sun.max")
        add(tab.isLocked ? "Unlock" : "Lock",
            #selector(toggleLockedFromMenu(_:)),
            symbol: tab.isLocked ? "lock.open.fill" : "lock.fill")
        add(tab.keepsInSidebar ? "Allow Archiving" : "Keep in Sidebar",
            #selector(toggleKeepInSidebarFromMenu(_:)),
            symbol: tab.keepsInSidebar ? "clock" : "clock.badge.xmark",
            // Archiving off means there is nothing to be kept from, and an
            // enabled switch that guards against nothing is a puzzle.
            enabled: settings.tabArchiveDelay != nil)
        // Sleeping the tab you are looking at would blank it, so the one tab
        // that cannot be put to sleep is the visible one.
        add("Sleep Now", #selector(sleepTabFromMenu(_:)), symbol: "moon.zzz",
            enabled: tab.isLoaded && !session.visibleTabIDs.contains(tab.id))
        add("Archive Now", #selector(archiveTabFromMenu(_:)), symbol: "archivebox",
            enabled: !session.isPinned(tab) && !shownSpace.isPrivate)
        menu.addItem(.separator())
        add("Open as Split", #selector(splitTabFromMenu(_:)), symbol: "rectangle.split.2x1",
            enabled: space.tabs.count > 1)
        add("Duplicate", #selector(duplicateTabFromMenu(_:)), symbol: "plus.square.on.square")
        menu.addItem(.separator())
        add("New Folder with Tab", #selector(newGroupWithTabFromMenu(_:)), symbol: "folder.badge.plus",
            key: "n", modifiers: [.control, .command])
        let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        move.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        let spaces = NSMenu()
        for candidate in session.sidebarSpaces where candidate !== space {
            let item = NSMenuItem(title: candidate.name, action: #selector(moveTabToSpaceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [tab, candidate]
            item.image = candidate.isPrivate
                ? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)
                : candidate.dotImage()
            spaces.addItem(item)
        }
        move.submenu = spaces
        move.isEnabled = !spaces.items.isEmpty
        menu.addItem(move)
        menu.addItem(.separator())
        add("Rename\u{2026}", #selector(renameTabFromMenu(_:)), symbol: "pencil")
        let colour = NSMenuItem(title: "Colour Tag", action: nil, keyEquivalent: "")
        colour.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        let colours = NSMenu()
        let none = NSMenuItem(title: "None", action: #selector(setTabColorFromMenu(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = [tab]
        none.state = tab.colorTag == nil ? .on : .off
        colours.addItem(none)
        for tag in TabColorTag.allCases {
            let item = NSMenuItem(title: tag.title, action: #selector(setTabColorFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [tab, tag.rawValue]
            item.image = tag.dotImage()
            item.state = tab.colorTag == tag ? .on : .off
            colours.addItem(item)
        }
        colour.submenu = colours
        menu.addItem(colour)
        let reloadItem = NSMenuItem(title: "Auto Reload", action: nil, keyEquivalent: "")
        reloadItem.image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: nil)
        let intervals = NSMenu()
        let off = NSMenuItem(title: "Off", action: #selector(setAutoReloadFromMenu(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = [tab]
        off.state = tab.autoReloadInterval == nil ? .on : .off
        intervals.addItem(off)
        for seconds in Tab.autoReloadChoices {
            let item = NSMenuItem(title: Self.autoReloadTitle(seconds), action: #selector(setAutoReloadFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [tab, seconds]
            item.state = tab.autoReloadInterval == seconds ? .on : .off
            intervals.addItem(item)
        }
        reloadItem.submenu = intervals
        menu.addItem(reloadItem)
        add(tab.note == nil ? "Add Note\u{2026}" : "Edit Note\u{2026}", #selector(editNoteFromMenu(_:)), symbol: "note.text")
        add(tab.emoji == nil ? "Set Emoji\u{2026}" : "Change Emoji\u{2026}", #selector(editEmojiFromMenu(_:)), symbol: "face.smiling")
        menu.addItem(.separator())
        // Greyed rather than hidden. A Close that has gone missing looks like
        // a bug in the menu; a Close that is there and cannot be pressed,
        // directly under an item that says "Unlock", explains itself.
        add("Close", #selector(closeTabFromMenu(_:)), symbol: "xmark", key: "w",
            enabled: !tab.isLocked)
        add("Close Other Tabs", #selector(closeOtherTabsFromMenu(_:)), enabled: space.tabs.count > 1)
        let isLast = space.index(of: tab).map { $0 == space.tabs.count - 1 } ?? true
        add("Close Tabs Below", #selector(closeTabsBelowFromMenu(_:)), enabled: !isLast)
        add("Close All Tabs in Space", #selector(closeAllTabsInSpaceFromMenu(_:)), symbol: "xmark.square")
        return menu
    }

    /// The compact folder menu follows Arc's grouping. Holding Option reveals
    /// Markdown copying and the older folder appearance and locking controls.
    func makeGroupMenu(for group: TabGroup) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        let owner = session.spaces.first { $0.group(withID: group.id) === group }
        @discardableResult
        func add(_ title: String, _ selector: Selector, alternate: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = group
            item.isAlternate = alternate
            if alternate { item.keyEquivalentModifierMask = .option }
            menu.addItem(item)
            return item
        }
        if !group.isLive {
            add("New Nested Folder…", #selector(newNestedFolderFromMenu(_:)))
                .isEnabled = owner.map { FolderTree.canAcceptSubfolder(group, in: $0.groups) } ?? false
            add("Turn “\(group.name)” into Space", #selector(turnFolderIntoSpaceFromMenu(_:))).isEnabled = !group.isLocked
            add("Copy All Links", #selector(copyFolderLinksFromMenu(_:)))
                .isEnabled = owner.map { !FolderContents.tabs(in: group, space: $0).isEmpty } ?? false
            add("Copy All Links as Markdown", #selector(copyFolderMarkdownFromMenu(_:)), alternate: true)
                .isEnabled = owner.map { !FolderContents.tabs(in: group, space: $0).isEmpty } ?? false
            menu.addItem(.separator())
            add("Change Icon…", #selector(changeFolderIconFromMenu(_:)))
            add("Customize Appearance…", #selector(customizeGroupFromMenu(_:)), alternate: true)
            add("Rename…", #selector(renameGroupFromMenu(_:)))
            menu.addItem(.separator())
            add("Duplicate", #selector(duplicateFolderFromMenu(_:)))
            add(group.isCollapsed ? "Expand" : "Collapse", #selector(toggleGroupCollapsedFromMenu(_:)), alternate: true)
            let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let spaces = NSMenu(); spaces.autoenablesItems = false
            for candidate in session.sidebarSpaces {
                let item = NSMenuItem(title: candidate.name, action: #selector(moveGroupToSpaceFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [group, candidate]
                item.state = candidate === owner ? .on : .off
                item.isEnabled = true
                item.image = candidate.menuImage()
                spaces.addItem(item)
            }
            spaces.addItem(.separator())
            let newSpace = NSMenuItem(title: "New Space…", action: #selector(moveFolderToNewSpaceFromMenu(_:)), keyEquivalent: "")
            newSpace.target = self; newSpace.representedObject = group
            spaces.addItem(newSpace)
            move.submenu = spaces
            menu.addItem(move)
        } else {
            let options = LiveFolderOptionsMenu.menu(for:session.liveFolders.options(for:group.id)) { [weak self,weak group] change in
                guard let self,let group,session.spaces.contains(where:{ $0.group(withID:group.id) === group }) else { return }
                session.liveFolders.apply(change,to:group.id)
            }
            let parent = NSMenuItem(title:"Options",action:nil,keyEquivalent:"");parent.submenu = options;menu.addItem(parent)
            add(group.isCollapsed ? "Expand" : "Collapse", #selector(toggleGroupCollapsedFromMenu(_:)))
        }
        if !group.isLive,group.symbolName == "arc.github.folder",let owner,!owner.isPrivate {
            let item = NSMenuItem(title:"Enable Live Updates",action:#selector(SidebarMenuAction.run),keyEquivalent:"")
            let target = SidebarMenuAction { [weak self,weak group,weak owner] in
                if let self,let group,let owner { session.enableGitHubLiveFolder(group,in:owner) }
            }
            item.target = target;item.representedObject = target;menu.addItem(item)
        }
        menu.addItem(.separator())
        add("Delete", #selector(removeGroupFromMenu(_:))).isEnabled = !group.isLocked
        add(group.isLocked ? "Unlock Folder" : "Lock Folder", #selector(toggleGroupLockedFromMenu(_:)), alternate: !group.isLive)
        return menu
    }

    @objc private func copyFolderLinksFromMenu(_ sender: Any?) { copyFolderLinks(sender, markdown: false) }
    @objc private func copyFolderMarkdownFromMenu(_ sender: Any?) { copyFolderLinks(sender, markdown: true) }

    private func copyFolderLinks(_ sender: Any?, markdown: Bool) {
        guard let group = group(from: sender),
              let owner = session.spaces.first(where: { $0.group(withID: group.id) === group }) else { return }
        let text = FolderContents.links(in: group, space: owner, markdown: markdown)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func duplicateFolderFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        do { try session.duplicateFolder(group) }
        catch {
            if let window = view.window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc private func turnFolderIntoSpaceFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        session.turnFolderIntoSpace(group)
    }

    @objc private func moveFolderToNewSpaceFromMenu(_ sender: Any?) {
        guard let group = group(from: sender), !group.isLive,
              let owner = session.spaces.first(where: { $0.group(withID: group.id) === group }) else { return }
        presentNewSpaceSheet(initialPrivate: owner.isPrivate, movingFolder: group)
    }

    @objc private func changeFolderIconFromMenu(_ sender: Any?) {
        guard let group = group(from: sender), !group.isLive,
              let owner = session.spaces.first(where: { $0.group(withID: group.id) === group }) else { return }
        session.selectSpace(owner)
        guard let row = groupRow(of: group),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true),
              let header = cell.subviews.compactMap({ $0 as? TabGroupHeaderView }).first else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = FolderIconPicker(selected: group.icon) { [weak self, weak group] icon in
            guard let self, let group,
                  session.spaces.contains(where: { $0.group(withID: group.id) === group }) else { return }
            session.setIcon(icon, for: group)
            folderIconPopover?.performClose(nil)
        }
        folderIconPopover = popover
        let anchor = header.iconPickerAnchor
        popover.show(relativeTo: anchor.bounds.offsetBy(dx: 1, dy: -3), of: anchor, preferredEdge: .minY)
    }

    @objc private func moveGroupToSpaceFromMenu(_ sender: Any?) {
        guard let pair = (sender as? NSMenuItem)?.representedObject as? [Any],
              pair.count == 2, let group = pair[0] as? TabGroup, let space = pair[1] as? Space
        else { return }
        session.move(group, toSpace: space)
    }

    private func group(from sender: Any?) -> TabGroup? {
        (sender as? NSMenuItem)?.representedObject as? TabGroup
    }

    @objc private func renameGroupFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        beginNamingFolder(group)
    }

    private func beginNamingFolder(_ group: TabGroup) {
        folderNameEdit?.field.commit()
        guard !group.isLive, let space = session.spaces.first(where: { $0.group(withID: group.id) === group }) else { return }
        if isLibraryVisible { hideLibrary() }
        session.selectSpace(space)
        if space.look.pinnedSectionCollapsed {
            var look = space.look; look.pinnedSectionCollapsed = false
            session.setLook(look, for: space)
        }
        var ancestor = group.parentID
        var visited: Set<UUID> = [group.id]
        while let id = ancestor, visited.insert(id).inserted, let parent = space.group(withID: id) {
            if parent.isCollapsed { session.toggleCollapsed(parent) }
            ancestor = parent.parentID
        }
        guard let row = groupRow(of: group) else { return }
        let id = UUID()
        let field = FolderNameEditor(name: group.name) { [weak self, weak group, weak space] name in
            guard let self, let edit = folderNameEdit, edit.id == id else { return }
            folderNameEdit = nil
            edit.field.removeFromSuperview()
            NSAccessibility.post(element: view, notification: .layoutChanged)
            if let name, let group, let space,
               session.spaces.contains(where: { $0 === space }), space.group(withID: group.id) === group {
                session.rename(group, to: name)
            }
            reloadTabs()
        }
        folderNameEdit = (id, space, group, field)
        tableView.scrollRowToVisible(row)
        // A table exposes synthesized rows to accessibility clients. Host the
        // persistent editor beside the table so it remains a normal text field
        // in that hierarchy, rather than adding a non-row to AXChildren.
        view.addSubview(field)
        positionFolderNameEditor()
        positionTabNameEditor()
        // A menu restores its previous responder as tracking ends. Focusing
        // synchronously would immediately blur and commit this new editor.
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, folderNameEdit?.field === field else { return }
            field.beginEditing()
            NSAccessibility.post(element: view, notification: .layoutChanged)
        }
    }

    private func positionFolderNameEditor() {
        guard let edit = folderNameEdit, shownSpace === edit.space else { return }
        guard let row = groupRow(of: edit.group) else { edit.field.commit(); return }
        guard
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true),
              let header = cell.subviews.compactMap({ $0 as? TabGroupHeaderView }).first else { return }
        cell.layoutSubtreeIfNeeded()
        let tableFrame = header.nameEditorFrame(in: tableView)
        let viewport = scrollView.contentView.convert(scrollView.contentView.bounds, to: tableView)
        // A row rebuild can briefly give the clip view a zero-sized viewport.
        // Wait for its next layout rather than committing during that transition.
        if viewport.height > 0, tableFrame.minY < viewport.minY || tableFrame.maxY > viewport.maxY {
            edit.field.commit(); return
        }
        var frame = view.convert(tableFrame, from: tableView)
        frame.size.width = max(0, min(frame.width, view.bounds.width - Style.Metrics.sidebarInset - frame.minX))
        edit.field.frame = frame
        header.isEditingName = true
    }

    private func beginNamingTab(_ tab: Tab, in space: Space) {
        folderNameEdit?.field.commit(); tabNameEdit?.field.commit()
        guard session.spaces.contains(where: { $0 === space }), space.tabs.contains(where: { $0 === tab }) else { return }
        if isLibraryVisible { hideLibrary() }
        session.selectSpace(space)
        if tab.isSidebarRetained, space.look.pinnedSectionCollapsed {
            var look = space.look; look.pinnedSectionCollapsed = false
            session.setLook(look, for: space)
        }
        var ancestor = tab.groupID
        var visited: Set<UUID> = []
        while let id = ancestor, visited.insert(id).inserted, let parent = space.group(withID: id) {
            if parent.isCollapsed { session.toggleCollapsed(parent) }
            ancestor = parent.parentID
        }
        guard let row = row(of: tab) else { return }
        let id = UUID(),splitID = space.splits.identifier(containing:tab.id)
        let initialName = splitID == nil ? tab.displayTitle : space.splits.name(containing:tab.id)
            ?? space.splits.layout(containing:tab.id)?.tabIDs.compactMap { member in space.tabs.first { $0.id == member }?.displayTitle }.joined(separator:" / ") ?? tab.displayTitle
        let field = FolderNameEditor(name: initialName, font: Style.Fonts.tabTitle, placeholder: "Tab Title", label: splitID == nil ? "Tab name":"Split name") {
            [weak self, weak tab, weak space] name in
            guard let self, let edit = tabNameEdit, edit.id == id else { return }
            tabNameEdit = nil
            edit.field.removeFromSuperview()
            if let tab, let space, let name, session.spaces.contains(where: { $0 === space }),
               space.tabs.contains(where: { $0 === tab }) {
                if let splitID {
                    if space.splits.identifier(containing:tab.id) == splitID { session.renameSplit(containing:tab.id,in:space,to:name) }
                } else if space.splits.identifier(containing:tab.id) == nil { session.rename(tab,to:name) }
            }
            reloadTabs()
            NSAccessibility.post(element: view, notification: .layoutChanged)
        }
        tabNameEdit = (id, space, tab, splitID, field)
        tableView.scrollRowToVisible(row)
        view.addSubview(field)
        positionTabNameEditor()
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, tabNameEdit?.field === field else { return }
            field.beginEditing()
            NSAccessibility.post(element: view, notification: .layoutChanged)
        }
    }

    private func positionTabNameEditor() {
        guard let edit = tabNameEdit, shownSpace === edit.space else { return }
        guard let row = row(of: edit.tab),
              let cell = tableView.view(atColumn:0,row:row,makeIfNecessary:true) else { edit.field.commit(); return }
        cell.layoutSubtreeIfNeeded()
        let tableFrame: NSRect
        if let cell = cell as? TabRowView {
            tableFrame = cell.nameEditorFrame(in:tableView)
            cell.isEditingName = true
        } else if let cell = cell as? SplitRowView, case .split(let split) = rows[row],
                  let index = split.tabs.firstIndex(where: { $0 === edit.tab }), cell.members.indices.contains(index) {
            _ = index
            tableFrame = cell.nameEditorFrame(in:tableView)
            cell.isEditingName = true
        } else { edit.field.commit(); return }
        let viewport = scrollView.contentView.convert(scrollView.contentView.bounds, to: tableView)
        if viewport.height > 0, tableFrame.minY < viewport.minY || tableFrame.maxY > viewport.maxY { edit.field.commit(); return }
        var frame = view.convert(tableFrame, from: tableView)
        frame.size.width = max(0, min(frame.width, view.bounds.width - Style.Metrics.sidebarInset - frame.minX))
        edit.field.frame = frame
    }

    @objc private func newNestedFolderFromMenu(_ sender: Any?) {
        guard let parent = group(from: sender), !parent.isLive,
              shownSpace.group(withID: parent.id) === parent,
              FolderTree.canAcceptSubfolder(parent, in: shownSpace.groups) else { return }
        let group = session.createGroup(named: "Untitled", parent: parent)
        beginNamingFolder(group)
    }

    @objc private func customizeGroupFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        openAppearanceEditor(for: group)
    }

    @objc private func toggleGroupCollapsedFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        session.toggleCollapsed(group)
    }

    @objc private func removeGroupFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        confirmRemoveGroup(group)
    }

    /// Confirms removing a group. The tabs move to the main list unless the
    /// user turns on "Delete all tabs in this group", which closes them too.
    private func confirmRemoveGroup(_ group: TabGroup) {
        let name = group.name.isEmpty ? "this group" : "\u{201c}\(group.name)\u{201d}"
        let alert = NSAlert()
        alert.messageText = "Delete the folder \(name)?"
        alert.informativeText = "Its tabs move to the main list. Turn on the option below to close them instead."
        let closeTabs = NSButton(checkboxWithTitle: "Delete all tabs in this folder", target: nil, action: nil)
        closeTabs.state = .off
        closeTabs.sizeToFit()
        closeTabs.frame = NSRect(x: 0, y: 0, width: max(closeTabs.frame.width, 260), height: closeTabs.frame.height)
        alert.accessoryView = closeTabs
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let commit = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            self?.session.removeGroup(group, closingTabs: closeTabs.state == .on)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: commit)
        } else {
            commit(alert.runModal())
        }
    }

    /// Shows the appearance editor beside a group's header. Anchored to the
    /// table rather than the header cell, which `reloadData` throws away on
    /// every live change, so the popover stays put while the user drags a well.
    private func openAppearanceEditor(for group: TabGroup) {
        guard let row = groupRow(of: group) else { return }
        let editor = GroupAppearanceEditor(
            appearance: group.appearance,
            tint: group.tint,
            name: group.name,
            icon: group.icon,
            onChange: { [weak self] appearance in
                self?.session.setAppearance(appearance, for: group)
            },
            onRename: { [weak self] name in
                self?.session.rename(group, to: name)
            },
            onIcon: { [weak self] icon in
                self?.session.setIcon(icon, for: group)
            }
        )
        let popover = NSPopover()
        popover.contentViewController = editor
        // Semitransient, not transient: the colour panel is another window, and
        // a transient popover would close the moment the user clicked into it.
        popover.behavior = .semitransient
        appearancePopover = popover
        popover.show(relativeTo: tableView.rect(ofRow: row), of: tableView, preferredEdge: .maxX)
    }

    private func groupRow(of group: TabGroup) -> Int? {
        rows.firstIndex {
            if case .group(let candidate, _, _) = $0 { return candidate.id == group.id }
            return false
        }
    }

    @discardableResult
    func revealFolder(_ group: TabGroup, in space: Space) -> Bool {
        _ = view
        guard session.openFolder(group,in:space) else { return false }
        hideLibrary()
        setArchiveVisible(false)
        view.layoutSubtreeIfNeeded()
        if let row = groupRow(of:group) { tableView.scrollRowToVisible(row) }
        return true
    }

    private func tab(from sender: Any?) -> Tab? {
        (sender as? NSMenuItem)?.representedObject as? Tab
    }

    @objc private func pinTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.pin(tab)
    }

    /// Keeping a tab awake does not wake it. The switch says what happens from
    /// here, and reloading a page the user cannot see -- to honour a preference
    /// they set for later -- would spend memory to obey the letter of a setting
    /// against its point.
    @objc private func toggleKeepAwakeFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        tab.setKeepsAwake(!tab.keepsAwake)
    }

    @objc private func toggleKeepInSidebarFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        tab.setKeepsInSidebar(!tab.keepsInSidebar)
    }

    @objc private func toggleLockedFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        tab.setLocked(!tab.isLocked)
    }

    @objc private func toggleGroupLockedFromMenu(_ sender: Any?) {
        guard let group = group(from: sender) else { return }
        session.setLocked(!group.isLocked, for: group)
    }

    /// Sleeps one tab by hand. Clearing "Keep Awake" first, because asking for
    /// this while the lock is on is the clearest possible statement that the
    /// lock is no longer wanted -- and silently doing nothing would look broken.
    @objc private func sleepTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        tab.setKeepsAwake(false)
        session.suspend([tab])
    }

    /// Archives one tab by hand, with no threshold and no waiting. Same reading
    /// of an explicit request as above: the locks that exist to stop this
    /// happening *automatically* do not stop the user doing it deliberately.
    @objc private func archiveTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.archive([tab])
    }

    /// The clicked tab beside the visible one; or, when it is the visible
    /// one, beside its neighbour, which is what the Split menu items do.
    @objc private func splitTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        splitTab(tab)
    }

    private func splitTab(_ tab: Tab) {
        let tabs = session.activeSpace.tabs
        if let current = session.activeTab, current !== tab {
            session.splitTabs([current, tab], grid: .sideBySide)
            return
        }
        guard tabs.contains(where: { $0 === tab }) else { return }
        onChooseSplitPage?()
    }

    @objc private func duplicateTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.duplicate(tab)
    }

    @objc private func newGroupWithTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender), session.activeSpace.index(of: tab) != nil,
              tab.pinnedSiteID == nil else { return }
        let group = session.createGroup(named: "Untitled", containing: [tab])
        beginNamingFolder(group)
    }

    @objc private func moveTabToSpaceFromMenu(_ sender: Any?) {
        guard let pair = (sender as? NSMenuItem)?.representedObject as? [Any],
              pair.count == 2, let tab = pair[0] as? Tab, let space = pair[1] as? Space
        else { return }
        session.move(tab, toSpace: space)
    }

    static func autoReloadTitle(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "Every \(Int(seconds)) seconds" : "Every \(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")"
    }

    @objc private func setAutoReloadFromMenu(_ sender: Any?) {
        guard let payload = (sender as? NSMenuItem)?.representedObject as? [Any],
              let tab = payload.first as? Tab else { return }
        let seconds = payload.count > 1 ? payload[1] as? TimeInterval : nil
        tab.setAutoReload(every: seconds)
        session.showToast?(Toast(
            symbolName: "arrow.clockwise.circle",
            message: seconds.map { "Reloading \(Self.autoReloadTitle($0).lowercased())" } ?? "Auto reload off",
            identity: "auto-reload"
        ))
    }

    @objc private func editEmojiFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        guard let emoji = TextPrompt.ask(
            title: "Emoji for This Tab",
            message: "Shown in place of the favicon. Leave it empty to go back to the favicon.",
            initial: tab.emoji ?? "", placeholder: "🚀", confirm: "Set", width: 120
        ) else { return }
        tab.setEmoji(emoji)
    }

    @objc private func editNoteFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        guard let note = TextPrompt.ask(
            title: tab.note == nil ? "Add a Note" : "Edit the Note",
            message: "Shown when you hover the tab. Leave it empty to remove the note.",
            initial: tab.note ?? "", placeholder: "Why this tab is open", confirm: "Save", width: 280
        ) else { return }
        tab.setNote(note)
    }

    @objc private func setTabColorFromMenu(_ sender: Any?) {
        guard let payload = (sender as? NSMenuItem)?.representedObject as? [Any],
              let tab = payload.first as? Tab else { return }
        let tag = (payload.count > 1 ? payload[1] as? String : nil).flatMap(TabColorTag.init(rawValue:))
        session.setColorTag(tag, for: tab)
    }

    @objc private func renameTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        // The current custom name, or nothing: clearing the field puts the
        // page's own title back, so the prompt must not seed it with
        // a title the user never typed.
        guard let name = TextPrompt.ask(
            title: "Rename Tab",
            message: "Leave it empty to go back to the page's own title.",
            initial: tab.customName ?? "", placeholder: tab.displayTitle, width: 220
        ) else { return }
        session.rename(tab, to: name)
    }

    /// The deliberate, single-tab close. Refusal is reported here rather than
    /// swallowed, unlike the sweeps below, which step around a locked tab
    /// without comment because stepping around it is the point.
    @objc private func closeTabFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.closeTab(tab)
    }

    @objc private func closeOtherTabsFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.closeOtherTabs(than: tab)
    }

    @objc private func closeTabsBelowFromMenu(_ sender: Any?) {
        guard let tab = tab(from: sender) else { return }
        session.closeTabs(below: tab)
    }

    /// Context menu presented when multiple tabs are selected in the sidebar.
    func makeMultiTabMenu(for tabs: [Tab]) -> NSMenu {
        let menu = NSMenu()
        let space = session.activeSpace
        menu.autoenablesItems = false

        let count = tabs.count
        let reloadItem = NSMenuItem(title: "Reload \(count) Tabs", action: #selector(reloadSelectedTabsFromMenu(_:)), keyEquivalent: "r")
        reloadItem.target = self
        reloadItem.representedObject = tabs
        reloadItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(reloadItem)

        let duplicateItem = NSMenuItem(title: "Duplicate \(count) Tabs", action: #selector(duplicateSelectedTabsFromMenu(_:)), keyEquivalent: "")
        duplicateItem.target = self
        duplicateItem.representedObject = tabs
        duplicateItem.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
        menu.addItem(duplicateItem)

        let allPinned = tabs.allSatisfy { session.isPinned($0) }
        let pinTitle = allPinned ? "Unpin \(count) Tabs" : "Pin \(count) Tabs"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(pinSelectedTabsFromMenu(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.representedObject = tabs
        pinItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let groupItem = NSMenuItem(title: "New Folder with \(count) Tabs", action: #selector(newGroupWithSelectedTabsFromMenu(_:)), keyEquivalent: "")
        groupItem.target = self
        groupItem.representedObject = tabs
        groupItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        menu.addItem(groupItem)

        let moveItem = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        moveItem.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        let spacesMenu = NSMenu()
        for candidate in session.sidebarSpaces where candidate !== space {
            let item = NSMenuItem(title: candidate.name, action: #selector(moveSelectedTabsToSpaceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [tabs, candidate]
            item.image = candidate.isPrivate
                ? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)
                : candidate.dotImage()
            spacesMenu.addItem(item)
        }
        moveItem.submenu = spacesMenu
        moveItem.isEnabled = !spacesMenu.items.isEmpty
        menu.addItem(moveItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close \(count) Tabs", action: #selector(closeSelectedTabsFromMenu(_:)), keyEquivalent: "w")
        closeItem.target = self
        closeItem.representedObject = tabs
        closeItem.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        menu.addItem(closeItem)

        let otherCount = shownSpace.tabs.filter { candidate in
            !tabs.contains(where: { $0.id == candidate.id }) && !session.isPinned(candidate)
        }.count
        let closeOthersItem = NSMenuItem(title: "Close Other Tabs", action: #selector(closeOtherThanSelectedTabsFromMenu(_:)), keyEquivalent: "")
        closeOthersItem.target = self
        closeOthersItem.representedObject = tabs
        closeOthersItem.isEnabled = otherCount > 0
        menu.addItem(closeOthersItem)

        let closeAllItem = NSMenuItem(title: "Close All Tabs in Space", action: #selector(closeAllTabsInSpaceFromMenu(_:)), keyEquivalent: "")
        closeAllItem.target = self
        closeAllItem.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        closeAllItem.isEnabled = !shownSpace.tabs.isEmpty
        menu.addItem(closeAllItem)

        return menu
    }

    private func makeSplitMenu(for split:SidebarSplitRow) -> NSMenu {
        let menu = NSMenu();menu.autoenablesItems = false;menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        let owner = shownSpace
        func add(_ title:String,enabled:Bool = true,action:@escaping ()->Void) {
            let target = SidebarMenuAction { [weak self,weak owner] in
                // A native menu still owns focus while its action runs. Wait
                // until tracking ends before opening an editor or popover.
                DispatchQueue.main.async { [weak self,weak owner] in
                    guard let self,let owner,session.spaces.contains(where:{ $0 === owner }),
                          owner.splits.identifier(containing:split.anchor.id) == split.id else { return }
                    action()
                }
            }
            let item = NSMenuItem(title:title,action:#selector(SidebarMenuAction.run),keyEquivalent:"")
            item.target = target;item.representedObject = target;item.isEnabled = enabled;menu.addItem(item)
        }
        add("Copy Links") { [weak self] in
            guard self != nil else { return };NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(split.tabs.map { $0.url.absoluteString }.joined(separator:"\n"),forType:.string)
        }
        menu.addItem(.separator())
        add("Change Icon…") { [weak self,weak owner] in
            guard let self,let owner else { return }
            let popover = NSPopover();popover.behavior = .transient
            popover.contentViewController = CompactSpaceIconPicker(selected:owner.splits.icon(containing:split.anchor.id),label:"Split icon") { [weak self,weak owner,weak popover] icon in
                if let self,let owner,owner.splits.identifier(containing:split.anchor.id) == split.id {
                    session.setSplitIcon(icon,containing:split.anchor.id,in:owner)
                }
                popover?.close()
            }
            tabIconPopover?.close();tabIconPopover = popover
            popover.show(relativeTo:tableView.rect(ofRow:row(of:split.anchor) ?? 0),of:tableView,preferredEdge:.minY)
        }
        add("Rename…") { [weak self,weak owner] in if let self,let owner { beginNamingTab(split.anchor,in:owner) } }
        let muted = split.tabs.allSatisfy(\.isMuted)
        add(muted ? "Unmute":"Mute",enabled:split.tabs.contains { $0.isPlayingAudio || $0.isMuted }) {
            for page in split.tabs where page.isMuted == muted { page.toggleMute() }
        }
        menu.addItem(.separator())
        add("Add Split View",enabled:split.tabs.count<SplitLayout.maximumPanes) { [weak self,weak owner] in
            guard let self,let owner else { return };session.selectSpace(owner);session.selectTab(split.anchor);onChooseSplitPage?()
        }
        add("Separate Tabs") { [weak self,weak owner] in
            guard let self,let owner else { return };session.selectSpace(owner);session.selectTab(split.anchor);session.unsplit()
        }
        add("Duplicate") { [weak self] in _ = self?.session.duplicateTabs(split.tabs) }
        let move = NSMenuItem(title:"Move to",action:nil,keyEquivalent:"");let destinations = NSMenu()
        destinations.autoenablesItems = false
        for candidate in session.sidebarSpaces where candidate !== owner {
            let item = NSMenuItem(title:candidate.name,action:#selector(SidebarMenuAction.run),keyEquivalent:"")
            let target = SidebarMenuAction { [weak self,weak owner,weak candidate] in
                guard let self,let owner,let candidate,owner.splits.identifier(containing:split.anchor.id) == split.id else { return }
                session.moveTabs(split.tabs,toSpace:candidate)
            }
            item.target = target;item.representedObject = target;item.image = candidate.menuImage();destinations.addItem(item)
        }
        move.submenu = destinations;move.isEnabled = !destinations.items.isEmpty;menu.addItem(move)
        menu.addItem(.separator())
        add(split.tabs.allSatisfy(\.isSidebarRetained) ? "Remove Pin":"Pin",enabled:session.canChangeSidebarPin(split.anchor)) { [weak self,weak owner] in
            guard let self,let owner else { return };session.selectSpace(owner)
            session.setSidebarPin(!split.anchor.isSidebarRetained,for:split.anchor)
        }
        add("Archive Tab",enabled:split.tabs.allSatisfy { !$0.isLocked }) { [weak self] in self?.session.archive(split.tabs) }
        let panes = NSMenuItem(title:"Tabs",action:nil,keyEquivalent:"");let paneMenu = NSMenu()
        for page in split.tabs {
            let target = SidebarMenuAction { [weak self,weak owner,weak page] in
                guard let self,let owner,let page,owner.splits.identifier(containing:page.id) == split.id else { return }
                session.selectSpace(owner);session.selectTab(page)
            }
            let item = NSMenuItem(title:page.displayTitle,action:#selector(SidebarMenuAction.run),keyEquivalent:"")
            item.target = target;item.representedObject = target
            let choices = NSMenu()
            let focus = NSMenuItem(title:"Focus Tab",action:#selector(SidebarMenuAction.run),keyEquivalent:"")
            focus.target = target;focus.representedObject = target;choices.addItem(focus)
            let detachTarget = SidebarMenuAction { [weak self,weak owner,weak page] in
                if let self,let owner,let page,owner.splits.identifier(containing:page.id) == split.id { session.detachSplitPane(page,in:owner) }
            }
            let detach = NSMenuItem(title:"Remove from Split View",action:#selector(SidebarMenuAction.run),keyEquivalent:"")
            detach.target = detachTarget;detach.representedObject = detachTarget
            detach.isEnabled = split.tabs.allSatisfy { $0.pinnedSiteID == nil };choices.addItem(detach)
            item.submenu = choices;paneMenu.addItem(item)
        }
        panes.submenu = paneMenu;menu.addItem(panes)
        return menu
    }

    @objc private func reloadSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab] else { return }
        session.reloadTabs(tabs)
    }

    @objc private func duplicateSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab] else { return }
        session.duplicateTabs(tabs)
    }

    @objc private func pinSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab] else { return }
        let allPinned = tabs.allSatisfy { session.isPinned($0) }
        for tab in tabs {
            if allPinned {
                session.unpin(tab)
            } else if !session.isPinned(tab) {
                session.pin(tab)
            }
        }
    }

    @objc private func newGroupWithSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab],
              !tabs.isEmpty, tabs.allSatisfy({ session.activeSpace.index(of: $0) != nil && $0.pinnedSiteID == nil }) else { return }
        let group = session.createGroup(named: "Untitled", containing: tabs)
        beginNamingFolder(group)
    }

    @objc private func moveSelectedTabsToSpaceFromMenu(_ sender: Any?) {
        guard let pair = (sender as? NSMenuItem)?.representedObject as? [Any],
              pair.count == 2, let tabs = pair[0] as? [Tab], let space = pair[1] as? Space
        else { return }
        session.moveTabs(tabs, toSpace: space)
    }

    @objc private func closeSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab] else { return }
        session.closeTabs(tabs)
    }

    @objc private func closeOtherThanSelectedTabsFromMenu(_ sender: Any?) {
        guard let tabs = (sender as? NSMenuItem)?.representedObject as? [Tab] else { return }
        let toClose = shownSpace.tabs.filter { candidate in
            !tabs.contains(where: { $0.id == candidate.id }) && !session.isPinned(candidate)
        }
        session.closeTabs(toClose)
    }

    @objc func closeAllTabsInSpaceFromMenu(_ sender: Any?) {
        session.closeAllTabs(in: shownSpace)
    }

    /// The sheet that names a folder, marks it and colours it in one step --
    /// the New Space sheet's counterpart.
    ///
    /// A folder used to arrive from a text prompt with a name and nothing
    /// else, and then needed two more trips through two more menus to get the
    /// icon and the colour it was always going to get. It is the same panel
    /// the folder's own Customize Appearance opens, with a name on top.
    @objc private func newGroupFromMenu() {
        let group = session.createGroup(named: "Untitled")
        beginNamingFolder(group)
    }

    @objc private func newRSSGroupFromMenu() {
        guard let text = prompt(title: "New Live Group",
                                message: "The address of an RSS or Atom feed. The group is named after the feed once it loads.",
                                initial: "https://"),
              let url = URL(string: text), url.host() != nil
        else { return }
        session.createLiveGroup(source: .rss(RSSLiveFolderProvider.Configuration(feedURL: url)))
    }

    @objc private func newGitHubPullRequestsGroupFromMenu() { newGitHubGroup(scope: .pullRequests) }
    @objc private func newGitHubIssuesGroupFromMenu() { newGitHubGroup(scope: .issues) }

    private func newGitHubGroup(scope: GitHubLiveFolderProvider.Scope) {
        let noun = scope == .pullRequests ? "pull requests" : "issues"
        guard let login = prompt(title: "New Live Group",
                                 message: "The GitHub account signed in to this profile, whose \(noun) the group follows.",
                                 initial: "") else { return }
        session.createLiveGroup(source: .github(GitHubLiveFolderProvider.Configuration(login: login,useProfileSession:true,scope:scope)))
    }

    @objc private func bookmarkAllTabsFromMenu() {
        session.bookmarkAllTabs()
    }

    /// Small modal text prompt. AppKit has no stock one-field input sheet, so an
    /// alert with an accessory field is the shortest honest version.
    private func prompt(title: String, message: String, initial: String) -> String? {
        guard let name = TextPrompt.ask(title: title, message: message, initial: initial, width: 220), !name.isEmpty else { return nil }
        return name
    }
}

// MARK: - AddressBarDelegate

// MARK: - Tab list

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let source = makeContextMenu()
        replaceItems(in: menu, from: source)
    }

    func makeRowMenu(at clicked: Int) -> NSMenu {
        let source: NSMenu
        let selection = selectedTabs
        if tableView.selectedRowIndexes.count > 1, selection.count > 1, clicked >= 0, tableView.selectedRowIndexes.contains(clicked) {
            source = makeMultiTabMenu(for: selection)
        } else if rows.indices.contains(clicked), case .split(let split) = rows[clicked] {
            source = makeSplitMenu(for:split)
        } else if rows.indices.contains(clicked), case .tab(let tab, _, _) = rows[clicked] {
            source = makeTabMenu(for: tab, anchor: tableView.view(atColumn: 0, row: clicked, makeIfNecessary: true) ?? tableView)
        } else if rows.indices.contains(clicked), case .group(let group, _, _) = rows[clicked] {
            source = makeGroupMenu(for: group)
        } else if rows.indices.contains(clicked), case .newTab = rows[clicked] {
            source = makeContextMenu(anchor: tableView.view(atColumn: 0, row: clicked, makeIfNecessary: true) ?? tableView)
        } else {
            source = makeContextMenu()
        }
        return source
    }

    private func replaceItems(in menu: NSMenu, from source: NSMenu) {
        // Items belong to one menu at a time, so they are moved rather than
        // shared.
        let items = source.items
        source.removeAllItems()
        menu.items = items
        menu.autoenablesItems = source.autoenablesItems
        menu.allowsContextMenuPlugIns = source.allowsContextMenuPlugIns
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = source.automaticallyInsertsWritingToolsItems }
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    /// A folder's header row is taller by the gap its plate leaves above it,
    /// and the row that ends a plate by the space the plate leaves below its
    /// last pill, so the card has clearance at both ends.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return Style.Metrics.rowHeight }
        if case .newTab = rows[row] { return Style.Metrics.rowHeight + (hasVisibleRetainedRows ? 24 : 0) }
        if case .group(let group, _, _) = rows[row] {
            return Style.Metrics.groupHeaderHeight + (group.appearance.isStandard ? 0 : Style.Metrics.folderPlateGap)
                + plateGapBelow(row: row)
        }
        // The row that owns a plate's rounded bottom corners owns the padding
        // under them too. `plates` is rebuilt with `rows`, so it is already in
        // step by the time the table asks for a height -- including the asks
        // that come from `buildSlices`, which is why this reads `plates`
        // rather than the slices it is in the middle of computing.
        guard plates.indices.contains(row), plates[row].contains(where: { $0.segment == .bottom && isPaintedPlate($0) }) else {
            return Style.Metrics.rowHeight + plateGapBelow(row: row)
        }
        return Style.Metrics.rowHeight + Style.Metrics.folderPlateBottomPadding
            + plateGapBelow(row: row)
    }

    /// Clear space a card leaves under itself, before whatever comes next.
    ///
    /// A card is fenced off above by `folderPlateGap`, carried by its header's
    /// row. Nothing carried the same below it, so a card followed by a loose
    /// tab left three points between the card's edge and that tab's pill --
    /// less than the six two plain rows keep between each other. The card read
    /// as having caught the row underneath it.
    ///
    /// Nothing is added when the next row is another card's header, because
    /// that header already brings the gap with it, or when the next row is
    /// still inside a plate this row is also in, because that plate has not
    /// ended yet.
    private func plateGapBelow(row: Int) -> CGFloat {
        guard plates.indices.contains(row) else { return 0 }
        let visible = plates[row].filter(isPaintedPlate)
        guard !visible.isEmpty else { return 0 }
        let next = row + 1
        guard rows.indices.contains(next) else { return 0 }
        if case .group(let nextGroup, _, _) = rows[next], !nextGroup.appearance.isStandard { return 0 }
        let mine = Set(visible.compactMap(\.groupID))
        let theirs = Set(plates.indices.contains(next) ? plates[next].compactMap(\.groupID) : [])
        guard mine.isDisjoint(with: theirs) else { return 0 }
        return Style.Metrics.folderPlateGap
    }

    private func isPaintedPlate(_ piece: FolderPlatePlan.Piece) -> Bool {
        guard let id = piece.groupID else { return false }
        return shownSpace.group(withID: id)?.appearance.isStandard == false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(
            withIdentifier: FolderPlateRowView.reuseIdentifier,
            owner: self
        ) as? FolderPlateRowView ?? {
            let view = FolderPlateRowView()
            view.identifier = FolderPlateRowView.reuseIdentifier
            return view
        }()
        view.slices = slices.indices.contains(row) ? slices[row] : []
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = cellView(for: rows[row], row: row)
        // A row the table has just been told to insert springs in from the
        // leading edge. Done here rather than after the batch because this is
        // the one moment the view certainly exists: a row scrolled out of sight
        // is never built, and never needs an entrance either.
        if let cell, pendingEntrances.remove(rows[row].identity) != nil {
            SpringPresence.slideIn(cell, from: CGVector(dx: -Style.Motion.entrySlide, dy: 0))
        }
        return cell
    }

    private func cellView(for sidebarRow: SidebarRow, row: Int) -> NSView? {
        switch sidebarRow {
        case .group(let group, let depth, _):
            return groupHeaderCell(for: group, depth: depth)
        case .liveStatus(let group, let status, let depth):
            return liveStatusCell(status, depth: depth,group:group)
        case .newTab:
            return newTabRowCell()
        case .split(let split):
            let cell = tableView.makeView(withIdentifier:SplitRowView.reuseIdentifier,owner:self) as? SplitRowView ?? {
                let cell = SplitRowView(); cell.identifier = SplitRowView.reuseIdentifier; return cell
            }()
            configure(cell,with:split)
            cell.isSelected = tableView.selectedRowIndexes.contains(row)
            cell.isInGroupPlate = slices.indices.contains(row) && slices[row].contains { !$0.appearance.isStandard }
            return cell
        case .tab(let tab, let depth, _):
            let cell = tableView.makeView(
                withIdentifier: TabRowView.reuseIdentifier,
                owner: self
            ) as? TabRowView ?? {
                let cell = TabRowView()
                cell.identifier = TabRowView.reuseIdentifier
                return cell
            }()
            configure(cell, with: tab, depth: depth)
            cell.isSelected = tableView.selectedRowIndexes.contains(row)
            // A row with plate slices sits on a group plate, where its pill
            // needs a matching trailing margin so it does not run flush into
            // the plate's rounded right edge.
            cell.isInGroupPlate = slices.indices.contains(row) && slices[row].contains { !$0.appearance.isStandard }
            return cell
        }
    }

    /// The header carries its own height, so it is placed inside the taller row
    /// rather than fighting the table's row height.
    private func groupHeaderCell(for group: TabGroup, depth: Int) -> NSView {
        let header = TabGroupHeaderView()
        header.show(
            emoji: group.emoji,
            name: group.name,
            isExpanded: !group.isCollapsed,
            isLocked: group.isLocked,
            symbolName: group.symbolName,
            iconFileName: group.iconFileName,
            badgeIcon: group.badgeIcon,
            tint: group.appearance.isStandard ? shownSpace.color : group.tint,
            folderStroke: group.appearance.isStandard ? shownSpace.sidebarFolderColor : nil
        )
        header.onToggle = { [weak self] _ in self?.session.toggleCollapsed(group) }
        // The cross asks first, and by default keeps the tabs (they come back
        // out as loose rows); the confirmation offers to close them instead.
        header.onRemove = { [weak self] in self?.confirmRemoveGroup(group) }
        // A live folder is named and coloured by its provider, so it is not
        // offered the appearance editor.
        if !group.isLive {
            header.onCustomize = { [weak self] in self?.openAppearanceEditor(for: group) }
        }

        let container = NSView()
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Style.Metrics.sidebarInset + FolderTree.indent(forDepth: depth)
            ),
            // Full width, not hugging its text: the hover plate then covers the
            // same span as the pill on the tab rows underneath, which is what
            // makes a folder read as one block rather than as a caption with a
            // list beside it.
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Under the gap, measured from the top -- not centred, and not
            // pinned to the bottom. The header's row is taller than the header
            // by the gap above the plate, and, when the plate ends on this same
            // row, by the gap under it as well: an empty folder, or a collapsed
            // one, is a plate one row tall. Pinned to the bottom, the header
            // then sat in that lower gap, a clear ten points below the plate it
            // names -- a rounded card with the title hanging out underneath it.
            header.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: group.appearance.isStandard ? 0 : Style.Metrics.folderPlateGap
            )
        ])
        return container
    }

    /// Separates retained tabs above from today's tabs below.
    private var hasVisibleRetainedRows: Bool {
        (rows.firstIndex { if case .newTab = $0 { return true }; return false } ?? 0) > 0
    }

    private func newTabRowCell() -> NSView {
        let header = ActionRowView()
        header.show(symbolName: "plus", title: "New Tab")
        header.onPress = { [weak self] in self?.newTab() }

        let container = NSView()
        container.addSubview(header)
        let divider = SidebarSectionDivider()
        divider.isHidden = !hasVisibleRetainedRows
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            divider.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            divider.heightAnchor.constraint(equalToConstant: 1),
            header.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Style.Metrics.sidebarInset
            ),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            header.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: hasVisibleRetainedRows ? 12 : 0)
        ])
        return container
    }

    /// A live folder that is fetching, empty or failed says so in a row of its
    /// own rather than looking like an ordinary empty folder.
    private func liveStatusCell(_ status: LiveFolderStatus, depth: Int,group:TabGroup) -> NSView {
        let view = LiveFolderStatusView()
        view.show(status, indent: FolderTree.indent(forDepth: depth))
        view.onAction = { [weak self,weak group] in
            guard let self,let group,let owner = session.spaces.first(where:{ $0.group(withID:group.id) === group }) else { return }
            if case .failed(let issue) = status {
                if let url = session.liveFolders.recover(from:issue,folderID:group.id) {
                    session.selectSpace(owner);session.newTab(url:url)
                }
            } else { Task { await self.session.liveFolders.refresh(folderID:group.id) } }
        }

        let container = NSView()
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Style.Metrics.sidebarInset
            ),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            // At the top, not centred: a status row that ends a plate is taller
            // than its text, and the extra height belongs under the text, with
            // the plate's bottom edge, rather than under the row's top edge.
            view.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        return container
    }

    /// A group header and the New Tab row are controls, not destinations;
    /// selecting either would give the list a selection that names no page.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .tab = rows[row] { return true }
        if case .split = rows[row] { return true }
        return false
    }

    @objc private func activateTabRow(_ sender: NSTableView) {
        guard let event = NSApp.currentEvent, event.clickCount == 1,
              event.type == .leftMouseUp || event.type == .leftMouseDown,
              sender.clickedRow >= 0,
              let cell = sender.view(atColumn:0,row:sender.clickedRow,makeIfNecessary:false) else { return }
        let point = cell.convert(event.locationInWindow,from:nil)
        let keep = event.modifierFlags.contains(.command)
        if let cell = cell as? TabRowView { cell.activatePinnedIcon(at:point,keepingCurrentPage:keep) }
        else if let cell = cell as? SplitRowView { cell.activate(at:point,keepingCurrentPage:keep) }
    }

    private func refreshSelectionAppearance() {
        let selected = tableView.selectedRowIndexes
        for index in rows.indices {
            (tableView.view(atColumn:0,row:index,makeIfNecessary:false) as? TabRowView)?.isSelected = selected.contains(index)
            (tableView.view(atColumn:0,row:index,makeIfNecessary:false) as? SplitRowView)?.isSelected = selected.contains(index)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringDisplaySelection else { return }
        // A click that lands on nothing selectable -- the empty space below the
        // list, a folder header, the New Tab row -- makes `NSTableView` clear
        // its selection. The tab in front has not changed, so the sidebar must
        // not stop saying which tab that is: the pill would vanish while the
        // page it names is still on screen, and nothing in the window would
        // answer "which of these am I looking at?".
        //
        // The table's selection is put back on the active tab rather than the
        // pill being drawn from somewhere else, so that the selection the rest
        // of this file reads -- the multi-tab menu, the keyboard, the drag --
        // stays the truth. Re-selecting posts this notification again, and the
        // second pass takes the ordinary path.
        if tableView.selectedRowIndexes.isEmpty,
           let active = shownSpace.activeTab, let index = row(of: active) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            return
        }

        refreshSelectionAppearance()
        let targetRow = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard rows.indices.contains(targetRow) else { return }
        let target: Tab?
        switch rows[targetRow] {
        case .tab(let tab, _, _): target = tab
        case .split(let split):
            if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp,
               let cell = tableView.view(atColumn:0,row:targetRow,makeIfNecessary:true) as? SplitRowView,
               let member = cell.memberIndex(at:cell.convert(event.locationInWindow,from:nil)) {
                target = split.tabs[member]
            } else {
                let id = shownSpace.splits.preferredTab(containing:split.anchor.id)
                target = split.tabs.first { $0.id == id } ?? split.tabs.first
            }
        default: target = nil
        }
        if let target, session.activeTab !== target { session.selectTab(target) }

    }

    // Drag reordering, using AppKit's own table-view drag machinery.

    /// Stable page IDs survive table reloads and Space tab-array reordering.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row) else { return nil }
        // A top-level group header is draggable to reorder the groups. Only a
        // root: a nested group is held in place by its parent, so dragging its
        // row would look like it moved while nothing changed.
        if case .group(let group, let depth, _) = rows[row], depth == 0 {
            let item = NSPasteboardItem()
            item.setString(group.id.uuidString, forType: Self.groupRowType)
            return item
        }
        let tab: Tab
        switch rows[row] {
        case .tab(let member, _, _): tab = member
        case .split(let split): tab = split.anchor
        default: return nil
        }
        guard let index = session.activeSpace.index(of:tab) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(index), forType: Self.tabRowType)
        item.setString(tab.id.uuidString, forType: SidebarTabDrag.type)
        item.setString(session.activeSpace.id.uuidString,forType:SidebarTabDrag.ownerType)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        pinnedTiles.setTabDragInProgress(true);onTabDragStateChange?(true)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pinnedTiles.setTabDragInProgress(false);onTabDragStateChange?(false)
        self.tableView.showSplitDropPreview(nil)
    }

    /// What is being dragged, or nil for something this list does not take.
    private enum DropPayload {
        case favorite(Space,PinnedSite)
        case tabs([Tab])
        case link(URL)
        case group(TabGroup)
    }

    private func dropPayload(from info: any NSDraggingInfo) -> DropPayload? {
        let pasteboard = info.draggingPasteboard
        let items = pasteboard.pasteboardItems ?? []
        if items.contains(where:{ $0.types.contains(SidebarTabDrag.favoriteType) }) {
            guard let (source,site) = favoriteDrag(in:pasteboard),
                  session.canReceiveFavorite(site.id,from:source,into:session.activeSpace,copy:!info.draggingSourceOperationMask.contains(.move)) else { return nil }
            return .favorite(source,site)
        }
        if items.contains(where: { $0.types.contains(Self.groupRowType) }) {
            guard items.count == 1, let raw = items[0].string(forType:Self.groupRowType),
                  let id = UUID(uuidString:raw), let group = session.activeSpace.group(withID:id) else { return nil }
            return .group(group)
        }
        if items.contains(where: { $0.types.contains(SidebarTabDrag.type) || $0.types.contains(Self.tabRowType) }) {
            var tabs: [Tab] = []
            var seen: Set<UUID> = []
            let owners = Set(items.compactMap { $0.string(forType:SidebarTabDrag.ownerType) })
            guard owners.count<=1 else { return nil }
            let origin:Space
            if let raw = owners.first {
                guard let id = UUID(uuidString:raw),let source = session.spaces.first(where:{ $0.id == id }) else { return nil }
                origin = source
            } else { origin = session.activeSpace }
            for item in items {
                guard let raw = item.string(forType:SidebarTabDrag.type), let id = UUID(uuidString:raw),
                      let tab = origin.tabs.first(where: { $0.id == id }),
                      !tab.isSidebarPlaceholder else { return nil }
                if seen.insert(id).inserted { tabs.append(tab) }
            }
            if origin !== session.activeSpace,info.draggingSourceOperationMask.contains(.move) {
                let members = tabs.flatMap { origin.splits.layout(containing:$0.id)?.tabIDs ?? [$0.id] }
                guard members.allSatisfy({ id in origin.tabs.first(where:{ $0.id == id })?.pinnedSiteID == nil }) else { return nil }
            }
            return tabs.isEmpty ? nil : .tabs(tabs)
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            return .link(url)
        }
        return nil
    }

    private func allowedDropOperation(for payload:DropPayload, source:NSDragOperation) -> NSDragOperation {
        switch payload {
        case .tabs,.favorite:
            if source.contains(.move) { return .move }
            return source.contains(.copy) ? .copy : []
        case .group:
            return source.contains(.move) ? .move : []
        case .link:
            if source.contains(.copy) { return .copy }
            return source.contains(.link) ? .link : []
        }
    }

    /// Where dropping the dragged group would put it: just before this root
    /// group, or nil to send it past the last one. The first root header at or
    /// below the drop row that is not the dragged group itself.
    private func groupReorderTarget(dropRow: Int, dragged: TabGroup) -> TabGroup? {
        for index in min(max(0, dropRow), rows.count)..<rows.count {
            if case .group(let candidate, 0, _) = rows[index], candidate.id != dragged.id {
                return candidate
            }
        }
        return nil
    }

    /// The sidebar's rows in the shape the drop plan reads.
    private var dropRows: [TabDropPlan.Row] {
        rows.map { row in
            switch row {
            case .group(let group, let depth, _): return .folder(group, depth: depth)
            case .tab(let tab, let depth, let isEscaping): return .tab(tab, depth: depth, isEscaping: isEscaping)
            case .split(let split): return .tab(split.anchor,depth:split.depth,isEscaping:split.isEscaping)
            case .liveStatus(_, _, let depth): return .other(depth: depth)
            case .newTab: return .other(depth: 0)
            }
        }
    }

    /// Where a drop at this row would land, after the table has been told
    /// which row and operation to show. Nil refuses the drop.
    ///
    /// Shared by validation and acceptance, so what the indicator promised is
    /// what the drop does. A folder header is the one place the pointer's
    /// position within the row matters (`FolderDropZone`); everywhere else the
    /// drop is between rows, and a drop *on* a tab is treated as above it.
    private struct SidebarDropDestination {
        let plan: TabDropPlan.Destination
        let before: SidebarItem?
        let retained: Bool
    }

    private func dropLanding(_ plan: TabDropPlan.Destination?, at row: Int) -> SidebarDropDestination? {
        guard let plan else { return nil }
        let divider = rows.firstIndex { if case .newTab = $0 { return true }; return false } ?? rows.count
        return SidebarDropDestination(plan: plan, before: sidebarSiblingTarget(at: row, parentID: plan.groupID), retained: row <= divider)
    }

    private func dropDestination(
        _ info: any NSDraggingInfo,
        payload: DropPayload,
        row: Int,
        operation: NSTableView.DropOperation
    ) -> SidebarDropDestination? {
        let space = session.activeSpace
        if rows.indices.contains(row), case .group(let folder, _, _) = rows[row],
           let header = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) {
            let zonePayload: FolderDragPayload
            switch payload {
            case .tabs(let tabs):
                guard let tab = tabs.first else { return nil }
                if allowedDropOperation(for:payload,source:info.draggingSourceOperationMask) == .copy {
                    // New copies have no existing parent to reject. A move of
                    // mixed rows is fileable when any member is outside here.
                    zonePayload = .link
                } else {
                    zonePayload = .tab(tabs.first(where: { $0.groupID != folder.id }) ?? tab)
                }
            case .link,.favorite: zonePayload = .link
            // A dragged group reorders the groups; it is handled before this is
            // ever reached, and never files itself into a folder.
            case .group: return nil
            }
            let target = FolderDropZone.target(
                at: header.convert(info.draggingLocation, from: nil),
                in: header.bounds,
                isFlipped: header.isFlipped,
                folder: folder,
                tabCount: space.tabs(in: folder).count,
                payload: zonePayload,
                groups: space.groups
            )
            if case .afterFolder = target {
                let after = TabDropPlan.rowAfterBlock(of: row, rows: dropRows)
                tableView.setDropRow(after, dropOperation: .above)
                return dropLanding(TabDropPlan.onto(folder: folder, target: target, tabs: space.tabs, groups: space.groups), at: after)
            }
            guard target.highlightsFolder else { return nil }
            tableView.setDropRow(row, dropOperation: .on)
            guard let plan = TabDropPlan.onto(folder: folder, target: target, tabs: space.tabs, groups: space.groups) else { return nil }
            let before: SidebarItem?
            if case .intoFolderAtStart = target {
                before = SidebarOrder.items(groups: space.groups, tabs: space.listedTabs, parentID: folder.id).first
            } else {
                before = nil
            }
            return SidebarDropDestination(plan: plan, before: before, retained: true)
        }

        tableView.setDropRow(row, dropOperation: .above)
        return dropLanding(TabDropPlan.between(rows: dropRows, row: row, tabs: space.tabs, groups: space.groups), at: row)
    }

    private func isTabSplitDrop(onto target: SidebarSplitDropTarget, payload: DropPayload) -> Bool {
        let targetTab = target.tab
        switch payload {
        case .favorite(let source,let site):
            guard source.profile !== session.activeSpace.profile || targetTab.pinnedSiteID != site.id else { return false }
            let count = site.split?.members.count ?? 1
            let existing = session.activeSpace.splits.layout(containing:targetTab.id)?.paneCount ?? 1
            return existing+count<=SplitLayout.maximumPanes
        case .tabs(let tabs):
            guard !tabs.contains(where: { tab in
                tab.id == targetTab.id || session.activeSpace.splits.layout(containing:tab.id)?.contains(targetTab.id) == true
            }) else { return false }
            var proposed = session.activeSpace.splits
            var members = tabs.map(\.id)
            if let origin = session.spaces.first(where:{ owner in owner !== session.activeSpace && tabs.allSatisfy { page in owner.workspaceTabs.contains { $0 === page } } }) {
                var seen:Set<UUID> = []
                members = tabs.flatMap { origin.splits.layout(containing:$0.id)?.tabIDs ?? [$0.id] }.filter { seen.insert($0).inserted }
                proposed.copyCompleteGroups(from:origin.splits,mapping:Dictionary(uniqueKeysWithValues:members.map { ($0,$0) }))
            }
            return proposed.insert(members,beside:targetTab.id,on:target.side)
        case .link:
            return session.activeSpace.splits.layout(containing:targetTab.id)?.isFull != true
        case .group:
            return false
        }
    }

    private struct SidebarSplitDropTarget {
        let tab: Tab
        let side: SplitLayout.InsertionSide
        let preview: NSRect
    }

    private func splitDropTarget(at row:Int, info:any NSDraggingInfo) -> SidebarSplitDropTarget? {
        guard rows.indices.contains(row),
              let cell = tableView.view(atColumn:0,row:row,makeIfNecessary:true) else { return nil }
        cell.layoutSubtreeIfNeeded()
        let point = cell.convert(info.draggingLocation,from:nil)
        let tab: Tab
        let rect: NSRect
        switch rows[row] {
        case .tab(let page, _, _):
            guard let view = cell as? TabRowView else { return nil }
            tab = page; rect = view.pillRect
        case .split(let split):
            guard let view = cell as? SplitRowView else { return nil }
            if view.isNamed {
                tab = split.tabs[min(view.focusedIndex ?? 0,split.tabs.count-1)];rect = view.pillRect
                break
            }
            guard let index = view.members.indices.min(by: {
                      abs(view.members[$0].frame.midX-point.x) < abs(view.members[$1].frame.midX-point.x)
                  }), split.tabs.indices.contains(index) else { return nil }
            tab = split.tabs[index]; rect = view.members[index].frame
        default: return nil
        }
        guard rect.width > 0, rect.height > 0 else { return nil }
        let side: SplitLayout.InsertionSide = point.x < rect.midX ? .left : .right
        let preview = NSRect(x:side == .left ? rect.minX : rect.midX,y:rect.minY,
                             width:rect.width/2,height:rect.height).insetBy(dx:1,dy:1)
        return SidebarSplitDropTarget(tab:tab,side:side,preview:cell.convert(preview,to:tableView))
    }

    /// Resolve before mutating the session: its notifications rebuild the table synchronously.
    private func sidebarRootTarget(at row: Int) -> SidebarItem? {
        sidebarSiblingTarget(at: row, parentID: nil)
    }

    private func sidebarSiblingTarget(at row: Int, parentID: UUID?) -> SidebarItem? {
        guard rows.indices.contains(row) else { return nil }
        for index in row..<rows.count {
            switch rows[index] {
            case .group(let folder, _, _):
                if folder.parentID == parentID { return .folder(folder) }
            case .tab(let tab, _, _):
                if tab.groupID == parentID { return .tab(tab) }
            case .split(let split):
                if split.anchor.groupID == parentID { return .tab(split.anchor) }
            default: continue
            }
        }
        return nil
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        self.tableView.showSplitDropPreview(nil)
        guard shownSpace === session.activeSpace, let payload = dropPayload(from: info) else { return [] }
        let operation = allowedDropOperation(for:payload,source:info.draggingSourceOperationMask)
        guard !operation.isEmpty else { return [] }
        // A group drag reorders the top-level groups: the line goes between
        // rows and the move is always allowed (a drop on itself is a no-op).
        if case .group = payload {
            tableView.setDropRow(max(0, row), dropOperation: .above)
            return .move
        }
        if operation == .copy {
            switch payload {
            case .tabs,.favorite:
                guard dropDestination(info,payload:payload,row:row,operation:.above) != nil else { return [] }
                tableView.setDropRow(row,dropOperation:.above)
                return .copy
            default:break
            }
        }
        if dropOperation == .on, let target = splitDropTarget(at:row,info:info),
           isTabSplitDrop(onto:target,payload:payload) {
            tableView.setDropRow(row, dropOperation: .on)
            self.tableView.showSplitDropPreview(target.preview,color:shownSpace.color)
            return operation
        }
        guard dropDestination(info, payload: payload, row: row, operation: dropOperation) != nil
        else { return [] }
        return operation
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        defer { self.tableView.showSplitDropPreview(nil) }
        guard shownSpace === session.activeSpace, let payload = dropPayload(from: info) else { return false }
        let operation = allowedDropOperation(for:payload,source:info.draggingSourceOperationMask)
        guard !operation.isEmpty else { return false }
        if case .tabs(let dragged) = payload,
           let raw = info.draggingPasteboard.string(forType:SidebarTabDrag.ownerType),let id = UUID(uuidString:raw),
           let origin = session.spaces.first(where:{ $0.id == id }),origin !== session.activeSpace {
            let destination = dropDestination(info,payload:payload,row:row,operation:dropOperation)
            let splitTarget = dropOperation == .on ? splitDropTarget(at:row,info:info):nil
            guard destination != nil || splitTarget != nil else { return false }
            if let splitTarget,operation != .copy,!isTabSplitDrop(onto:splitTarget,payload:payload) { return false }
            return session.changes.batch {
                let pages = session.receiveSidebarTabs(dragged,from:origin,into:session.activeSpace,copy:operation == .copy)
                guard !pages.isEmpty else { return false }
                if let splitTarget,operation != .copy {
                    return session.splitSidebarTabs(pages,beside:splitTarget.tab,on:splitTarget.side)
                }
                guard let destination else { return false }
                let group = destination.plan.groupID.flatMap { session.activeSpace.group(withID:$0) }
                return session.moveSidebarTabs(pages,to:destination.plan.tabIndex,group:group,before:destination.before,retained:destination.retained)
            }
        }
        if case .favorite(let origin,let site) = payload {
            let destination = dropDestination(info,payload:payload,row:row,operation:dropOperation)
            let splitTarget = dropOperation == .on && operation != .copy ? splitDropTarget(at:row,info:info):nil
            guard destination != nil || splitTarget != nil else { return false }
            if let splitTarget, !isTabSplitDrop(onto:splitTarget,payload:payload) { return false }
            return session.changes.batch {
                let pages = session.receiveFavorite(site.id,from:origin,into:session.activeSpace,copy:operation == .copy)
                guard !pages.isEmpty else { return false }
                if let splitTarget { return session.splitSidebarTabs(pages,beside:splitTarget.tab,on:splitTarget.side) }
                guard let destination else { return false }
                let group = destination.plan.groupID.flatMap { session.activeSpace.group(withID:$0) }
                return session.moveSidebarTabs(pages,to:destination.plan.tabIndex,group:group,before:destination.before,retained:destination.retained)
            }
        }
        // A group drag reorders the top-level groups rather than moving a tab.
        if case .group(let dragged) = payload {
            if dragged.parentID == nil {
                session.positionSidebarItem(.folder(dragged), before: sidebarRootTarget(at: row))
            } else {
                session.moveGroup(dragged, before: groupReorderTarget(dropRow: row, dragged: dragged))
            }
            return true
        }
        if case .tabs(let tabs) = payload, operation == .copy {
            guard let destination = dropDestination(info,payload:payload,row:row,operation:.above) else { return false }
            let group = destination.plan.groupID.flatMap { session.activeSpace.group(withID:$0) }
            return session.duplicateSidebarTabs(tabs,to:destination.plan.tabIndex,group:group,
                                                before:destination.before,retained:destination.retained)
        }
        if dropOperation == .on, let target = splitDropTarget(at:row,info:info) {
            guard isTabSplitDrop(onto:target,payload:payload) else { return false }
            switch payload {
            case .tabs(let tabs):
                return session.splitSidebarTabs(tabs,beside:target.tab,on:target.side)
            case .link(let url):
                return session.openSidebarLink(url,splitting:target.tab,on:target.side)
            case .group,.favorite:
                break
            }
        }
        guard let destination = dropDestination(info, payload: payload, row: row, operation: dropOperation)
        else { return false }
        let space = session.activeSpace
        let group = destination.plan.groupID.flatMap { space.group(withID: $0) }

        switch payload {
        case .tabs(let tabs):
            return session.moveSidebarTabs(tabs,to:destination.plan.tabIndex,group:group,
                                           before:destination.before,retained:destination.retained)
        case .link(let url):
            return session.openSidebarLink(url,to:destination.plan.tabIndex,group:group,
                                           before:destination.before,retained:destination.retained)
        case .group,.favorite:
            // Handled above, before the tab destination is resolved.
            return true
        }
        return true
    }
}

/// A photograph of one space's sidebar content, placed by frame.
///
/// By frame and not by a layer transform, because AppKit owns the geometry of a
/// layer it backs a view with and puts the transform back to identity on the
/// next layout pass. Measured: a still given a translation of 91 points logged
/// that translation and drew at 0. The live content gets away with a transform
/// only because nothing lays it out again mid-drag.
@MainActor
private final class SpaceStillView: NSImageView {
    /// Where the content sits at rest, in the sidebar's coordinates.
    private let restFrame: NSRect

    /// How far from rest the still is, in points.
    var offsetX: CGFloat = 0 {
        didSet { frame = restFrame.offsetBy(dx: offsetX, dy: 0) }
    }

    init(image: NSImage, restFrame: NSRect) {
        self.restFrame = restFrame
        super.init(frame: restFrame)
        self.image = image
        imageScaling = .scaleNone
        autoresizingMask = []
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("SpaceStillView is created in code only")
    }
}

@MainActor
private final class SidebarMenuAction:NSObject {
    let action:()->Void
    init(_ action:@escaping ()->Void) { self.action = action }
    @objc func run() { action() }
}
