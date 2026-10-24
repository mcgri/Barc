// Modified for Barc: Arc-style Library category rail and searchable saved lists, 2026-10-24.
import AppKit
import Combine

@MainActor
final class SidebarLibraryView: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    static let railWidth = LibraryMetrics.rail
    static let listWidth = LibraryMetrics.list
    let header = SidebarHeaderView()
    var onClose: (() -> Void)?
    var onCategory: ((LibraryCategory) -> Void)?
    var onOpen: ((LibraryEntry) -> Void)?
    var onShareBrowser: ((NSView) -> Void)?
    private(set) var category: LibraryCategory
    private(set) var visibleEntries: [LibraryEntry] = []
    private let session: BrowserSession
    private let downloads: DownloadManager
    private let boosts: BoostStore
    private let defaults: UserDefaults
    private let search = NSSearchField()
    private let filter = NSButton(title: "Filter", target: nil, action: nil)
    private let list = NSView()
    private let categories = NSStackView()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private var buttons: [LibraryCategory: LibraryCategoryButton] = [:]
    private var queries: [LibraryCategory: LibraryQuery] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private enum Row { case date(String), entry(LibraryEntry) }
    private var rows: [Row] = []
    private var presented = false
    private var listConstraints: [NSLayoutConstraint] = []
    private var filterWidth: NSLayoutConstraint?
    private lazy var mediaIntro = LibraryMediaIntro { [weak self] in
        guard let self else { return }
        defaults.set(true, forKey: "sidebarLibraryMediaEnabled"); reload()
    }

    init(session: BrowserSession, downloads: DownloadManager = .shared, boosts: BoostStore = .shared, defaults: UserDefaults = .standard) {
        self.session = session; self.downloads = downloads; self.boosts = boosts; self.defaults = defaults
        category = defaults.string(forKey: "sidebarLibraryCategory").flatMap(LibraryCategory.init(rawValue:)) ?? .downloads
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        header.hostsTrafficLights = false
        build()
        session.changes.sink { [weak self] change in
            switch change {
            case .spaces, .structure, .tabs: self?.refreshIfShown()
            default: break
            }
        }.store(in: &subscriptions)
        downloads.changes.sink { [weak self] _ in self?.refreshIfShown() }.store(in: &subscriptions)
        boosts.changes.sink { [weak self] _ in self?.refreshIfShown() }.store(in: &subscriptions)
        select(category, remember: false)
    }
    required init?(coder: NSCoder) { fatalError("SidebarLibraryView is created in code only") }

    private func build() {
        let rail = NSView()
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.wantsLayer = true
        addSubview(rail)
        rail.addSubview(header)
        categories.orientation = .vertical; categories.spacing = 20
        categories.distribution = .fillEqually
        categories.translatesAutoresizingMaskIntoConstraints = false
        for category in LibraryCategory.allCases {
            let button = LibraryCategoryButton(category: category) { [weak self] in self?.select(category) }
            categories.addArrangedSubview(button); buttons[category] = button
        }
        rail.addSubview(categories)
        let back = IconButton(symbolName: "chevron.left", label: "Back to Sidebar", side: 28, symbolSize: 16) { [weak self] in self?.onClose?() }
        let share = IconButton(symbolName: "gift", label: "Share Barc", side: 28, symbolSize: 16)
        share.setClickHandler { [weak self, weak share] in if let share { self?.onShareBrowser?(share) } }
        rail.addSubview(back); rail.addSubview(share)
        list.translatesAutoresizingMaskIntoConstraints = false
        list.wantsLayer = true
        list.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.035).cgColor
        addSubview(list)
        search.translatesAutoresizingMaskIntoConstraints = false
        search.font = .systemFont(ofSize: 13)
        search.isBezeled = false
        search.drawsBackground = false
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search Library")
        let searchPlate = NSView()
        searchPlate.translatesAutoresizingMaskIntoConstraints = false
        searchPlate.wantsLayer = true
        searchPlate.layer?.cornerRadius = 10
        searchPlate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        searchPlate.addSubview(search)
        filter.translatesAutoresizingMaskIntoConstraints = false
        filter.isBordered = false; filter.font = .systemFont(ofSize: 12)
        filter.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        filter.imagePosition = .imageLeading
        filter.target = self; filter.action = #selector(showFilter)
        let column = NSTableColumn(identifier: .init("library"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear
        table.style = .fullWidth; table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Library items")
        let menu = NSMenu(); menu.delegate = self; table.menu = menu
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        emptyTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        emptyTitle.alignment = .center
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = .secondaryLabelColor; emptyDetail.alignment = .center
        let empty = NSStackView(views: [emptyTitle, emptyDetail])
        empty.orientation = .vertical; empty.spacing = 5
        empty.translatesAutoresizingMaskIntoConstraints = false
        [searchPlate, filter, scroll, empty, mediaIntro].forEach(list.addSubview)
        listConstraints = [list.leadingAnchor.constraint(equalTo: rail.trailingAnchor), list.topAnchor.constraint(equalTo: topAnchor),
                           list.trailingAnchor.constraint(equalTo: trailingAnchor), list.bottomAnchor.constraint(equalTo: bottomAnchor)]
        NSLayoutConstraint.activate(listConstraints)
        let filterWidth = filter.widthAnchor.constraint(equalToConstant: 64)
        self.filterWidth = filterWidth
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor), rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor), rail.widthAnchor.constraint(equalToConstant: Self.railWidth),
            header.leadingAnchor.constraint(equalTo: rail.leadingAnchor), header.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
            header.topAnchor.constraint(equalTo: rail.topAnchor),
            categories.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 8),
            categories.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -8),
            categories.centerYAnchor.constraint(equalTo: rail.centerYAnchor),
            categories.topAnchor.constraint(greaterThanOrEqualTo: header.bottomAnchor, constant: 10),
            categories.bottomAnchor.constraint(lessThanOrEqualTo: back.topAnchor, constant: -12),
            back.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 10), back.bottomAnchor.constraint(equalTo: rail.bottomAnchor, constant: -8),
            share.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -10), share.centerYAnchor.constraint(equalTo: back.centerYAnchor),
            searchPlate.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 12), searchPlate.topAnchor.constraint(equalTo: list.topAnchor, constant: 10),
            searchPlate.heightAnchor.constraint(equalToConstant: 36), searchPlate.trailingAnchor.constraint(equalTo: filter.leadingAnchor, constant: -4),
            search.leadingAnchor.constraint(equalTo: searchPlate.leadingAnchor, constant: 7), search.trailingAnchor.constraint(equalTo: searchPlate.trailingAnchor, constant: -7),
            search.centerYAnchor.constraint(equalTo: searchPlate.centerYAnchor),
            filter.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -8), filter.centerYAnchor.constraint(equalTo: searchPlate.centerYAnchor),
            filterWidth, filter.heightAnchor.constraint(equalToConstant: 32),
            scroll.topAnchor.constraint(equalTo: searchPlate.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor), empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -32),
            mediaIntro.centerXAnchor.constraint(equalTo: list.centerXAnchor), mediaIntro.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            mediaIntro.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -40)
        ])
        emptyTitle.superview?.identifier = .init("library.empty")
        setAccessibilityRole(.group); setAccessibilityLabel("Library")
    }

    func setPresented(_ value: Bool) { presented = value; if value { reload() } }
    override func layout() {
        categories.spacing = bounds.height < 700 ? 8 : 20
        super.layout()
    }
    func select(_ category: LibraryCategory, remember: Bool = true) {
        self.category = category
        if remember { defaults.set(category.rawValue, forKey: "sidebarLibraryCategory") }
        for (key, button) in buttons { button.isChosen = key == category }
        if category == .spaces {
            NSLayoutConstraint.deactivate(listConstraints); list.removeFromSuperview()
        } else if list.superview == nil { addSubview(list); NSLayoutConstraint.activate(listConstraints) }
        search.placeholderString = category.searchPlaceholder
        search.stringValue = queries[category]?.text ?? ""
        filter.isHidden = category == .boosts || category == .easels
        filterWidth?.constant = filter.isHidden ? 0 : 64
        onCategory?(category)
        reload()
    }
    func controlTextDidChange(_ notification: Notification) {
        var query = queries[category] ?? LibraryQuery(); query.text = search.stringValue; queries[category] = query
        reload()
    }
    private func refreshIfShown() { if presented { reload() } }
    func reload() {
        let entries = LibraryCatalog.entries(for: category, session: session, downloads: downloads, boosts: boosts)
        visibleEntries = (queries[category] ?? LibraryQuery()).apply(to: entries)
        let mediaEnabled = defaults.bool(forKey: "sidebarLibraryMediaEnabled")
        let introVisible = category == .media && !mediaEnabled
        if introVisible { visibleEntries = [] }
        search.isEnabled = !introVisible
        mediaIntro.isHidden = !introVisible
        rows = []
        var previousDay: Date?
        let calendar = Calendar.current
        let formatter = DateFormatter(); formatter.dateStyle = .medium
        for entry in visibleEntries {
            if category != .boosts {
                let day = calendar.startOfDay(for: entry.date)
                if day != previousDay {
                    let title = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday" : formatter.string(from: day)
                    rows.append(.date(title)); previousDay = day
                }
            }
            rows.append(.entry(entry))
        }
        table.reloadData()
        let searching = !(queries[category]?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        emptyTitle.stringValue = searching ? "No Results" : category == .easels ? "No Easels Yet" : "No \(category.title)"
        emptyDetail.stringValue = searching ? "Try a different search or filter." : category == .media ? "Images, videos and audio you download appear here." : category == .easels ? "Your saved Easels appear here." : category == .archive ? "Archived tabs stay here until you restore them." : ""
        emptyTitle.superview?.isHidden = !rows.isEmpty || category == .spaces || introVisible
        filter.isHidden = category == .boosts || category == .easels || introVisible
        filterWidth?.constant = filter.isHidden ? 0 : 64
        table.setAccessibilityValue("\(visibleEntries.count) items")
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }; if case .entry = rows[row] { return true }; return false
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .date = rows[row] { return 26 }; return category == .archive ? 48 : 56
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .date(let text):
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor
            let view = NSView(); label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            return view
        case .entry(let entry): return LibraryEntryView(entry: entry) { [weak self] in self?.onOpen?(entry) }
        }
    }
    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row), case .entry(let entry) = rows[row] else { return }
        onOpen?(entry)
    }
    @objc private func showFilter() {
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String, value: Any?, selected: Bool) {
            let item = NSMenuItem(title: title, action: #selector(filterChanged(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value; item.state = selected ? .on : .off; menu.addItem(item)
        }
        let query = queries[category] ?? LibraryQuery()
        if category == .downloads || category == .media {
            item("All File Types", value: "allTypes", selected: query.fileKind == nil)
            for kind in LibraryFileKind.allCases { item(kind.rawValue, value: kind, selected: query.fileKind == kind) }
            menu.addItem(.separator())
        }
        item("All Spaces", value: "allSpaces", selected: query.spaceID == nil)
        for space in session.spaces { item(space.name, value: space.id, selected: query.spaceID == space.id) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: filter.bounds.maxY), in: filter)
    }
    @objc private func filterChanged(_ sender: NSMenuItem) {
        var query = queries[category] ?? LibraryQuery()
        if let id = sender.representedObject as? UUID { query.spaceID = id }
        else if let kind = sender.representedObject as? LibraryFileKind { query.fileKind = kind }
        else if sender.representedObject as? String == "allTypes" { query.fileKind = nil }
        else { query.spaceID = nil }
        queries[category] = query; reload()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems(); menu.autoenablesItems = false
        guard rows.indices.contains(table.clickedRow), case .entry(let entry) = rows[table.clickedRow] else { return }
        let open = NSMenuItem(title: category == .archive ? "Restore Tab" : category == .boosts ? "Edit Boost…" : "Open", action: #selector(openMenuEntry(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = entry.id
        if case .download(let id) = entry.id { open.isEnabled = downloads.downloads.first { $0.id == id }?.fileExists == true }
        menu.addItem(open)
        if let url = entry.url {
            let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: "")
            copy.target = self; copy.representedObject = url; menu.addItem(copy)
        }
        if let file = entry.file {
            let reveal = NSMenuItem(title: "Show in Finder", action: #selector(revealFile(_:)), keyEquivalent: "")
            reveal.target = self; reveal.representedObject = file
            reveal.isEnabled = FileManager.default.fileExists(atPath: file.path); menu.addItem(reveal)
        }
    }
    @objc private func openMenuEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? LibraryEntry.ID,
              let entry = visibleEntries.first(where: { $0.id == id }) else { return }
        onOpen?(entry)
    }
    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    @objc private func revealFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

@MainActor
private final class LibraryMediaIntro: NSView {
    private let enable: () -> Void
    init(enable: @escaping () -> Void) {
        self.enable = enable
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true; layer?.cornerRadius = 14; layer?.backgroundColor = NSColor.white.cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemPurple
        let title = NSTextField(labelWithString: "Your Media in the Library")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "Find images, videos and audio from your browser downloads.")
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor; detail.alignment = .center
        let show = NSButton(title: "Show Media", target: self, action: #selector(showMedia))
        show.bezelStyle = .rounded
        let privacy = NSTextField(wrappingLabelWithString: "Media stays on this Mac.")
        privacy.font = .systemFont(ofSize: 10); privacy.textColor = .secondaryLabelColor; privacy.alignment = .center
        let stack = NSStackView(views: [icon, title, detail, show, privacy])
        stack.orientation = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            icon.heightAnchor.constraint(equalToConstant: 26), icon.widthAnchor.constraint(equalToConstant: 26),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor), privacy.widthAnchor.constraint(equalTo: stack.widthAnchor), show.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }
    @objc private func showMedia() { enable() }
}

@MainActor
private final class LibraryCategoryButton: NSButton {
    var isChosen = false { didSet { needsDisplay = true } }
    private let invoke: () -> Void
    init(category: LibraryCategory, invoke: @escaping () -> Void) {
        self.invoke = invoke
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title = category.title; image = NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil)
        imagePosition = .imageAbove; image?.size = NSSize(width: 25, height: 25)
        font = .systemFont(ofSize: 11, weight: .semibold)
        isBordered = false; target = self; action = #selector(choose)
        setAccessibilityLabel(category.title)
        let height = heightAnchor.constraint(equalToConstant: 80); height.priority = .defaultHigh; height.isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        widthAnchor.constraint(equalToConstant: 96).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }
    @objc private func choose() { invoke() }
    override func draw(_ dirtyRect: NSRect) {
        if isChosen { NSColor.black.withAlphaComponent(0.10).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
        super.draw(dirtyRect)
    }
}

@MainActor
private final class LibraryEntryView: NSView {
    private var tracking: NSTrackingArea?
    private var restore: IconButton?
    private var textTrailing: NSLayoutConstraint?
    init(entry: LibraryEntry, open: @escaping () -> Void) {
        super.init(frame: .zero)
        let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        if let data = entry.favicon { icon.image = NSImage(data: data) }
        else if let file = entry.file { icon.image = NSWorkspace.shared.icon(forFile: file.path) }
        else { icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil); icon.contentTintColor = .secondaryLabelColor }
        let title = NSTextField(labelWithString: entry.title), subtitle = NSTextField(labelWithString: entry.subtitle)
        title.font = .systemFont(ofSize: 13); subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
        for label in [title, subtitle] { label.lineBreakMode = .byTruncatingTail; label.setContentCompressionResistancePriority(.init(1), for: .horizontal) }
        let text = NSStackView(views: [title, subtitle]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(text)
        let trailing = text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        textTrailing = trailing
        if case .archived = entry.id {
            let button = IconButton(symbolName: "arrow.uturn.backward", label: "Restore Tab", side: 24, onClick: open)
            button.alphaValue = 0
            addSubview(button); restore = button
            NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), button.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), trailing,
            text.centerYAnchor.constraint(equalTo: centerYAnchor), title.widthAnchor.constraint(equalTo: text.widthAnchor), subtitle.widthAnchor.constraint(equalTo: text.widthAnchor)])
        setAccessibilityLabel(entry.title + ". " + entry.subtitle)
        toolTip = entry.title
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }
    override func updateTrackingAreas() { super.updateTrackingAreas(); tracking = installHoverTracking(replacing: tracking) }
    override func mouseEntered(with event: NSEvent) { restore?.alphaValue = 1; if restore != nil { textTrailing?.constant = -30 } }
    override func mouseExited(with event: NSEvent) { restore?.alphaValue = 0; textTrailing?.constant = -6 }
}
