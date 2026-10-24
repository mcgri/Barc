// Modified for Barc: compact Emoji/Icon Space picker, 2026-10-24.
import AppKit
import Combine

/// Fixed 270-point palette. The collection reuses visible cells while search
/// and category jumps operate on the locally bundled Unicode catalog.
@MainActor
final class CompactSpaceIconPicker: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate {
    enum Mode: Int { case emoji, icon }
    private(set) var mode: Mode
    private(set) var displayedEmoji: [SpaceEmojiCatalog.Entry] = SpaceEmojiCatalog.entries
    private let selected: SpaceIcon
    private let onChoose: (SpaceIcon) -> Void
    private let tabs = NSSegmentedControl(labels: ["Emoji", "Icon"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let trash = NSButton()
    private let scroll = NSScrollView()
    private let collection = GlyphCollection()
    private let footer = NSView()
    private let divider = NSBox()
    private let empty = NSTextField(labelWithString: "No emoji found")
    private var categoryButtons: [NSButton] = []
    private var scrollObserver: AnyCancellable?
    private static let itemID = NSUserInterfaceItemIdentifier("Space glyph")

    init(selected: SpaceIcon, onChoose: @escaping (SpaceIcon) -> Void) {
        self.selected = selected
        self.onChoose = onChoose
        if case .symbol = selected { mode = .icon } else { mode = .emoji }
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 270, height: 270)
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }

    override func loadView() {
        view = FlippedView(frame: NSRect(origin: .zero, size: preferredContentSize))
        view.setAccessibilityLabel("Space icon")
        tabs.frame = NSRect(x: 64, y: 14, width: 114, height: 24)
        tabs.segmentStyle = .rounded
        tabs.selectedSegment = mode.rawValue
        tabs.target = self; tabs.action = #selector(chooseGlyphMode)
        tabs.setAccessibilityLabel("Icon type")
        view.addSubview(tabs)

        trash.frame = NSRect(x: 185, y: 14, width: 26, height: 24)
        trash.title = ""; trash.isBordered = false
        trash.image = Self.templateImage("ionicon.trash-outline", side: 16)
        trash.contentTintColor = .secondaryLabelColor
        trash.target = self; trash.action = #selector(removeIcon)
        trash.toolTip = "Remove Icon"; trash.setAccessibilityLabel("Remove Icon")
        trash.isEnabled = selected.isCustomized
        view.addSubview(trash)

        search.frame = NSRect(x: 11, y: 48, width: 250, height: 24)
        search.placeholderString = "Search"
        search.font = .systemFont(ofSize: 13)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.setAccessibilityLabel("Search emoji")
        view.addSubview(search)

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 0, left: 1, bottom: 0, right: 1)
        collection.collectionViewLayout = layout
        collection.register(GlyphItem.self, forItemWithIdentifier: Self.itemID)
        collection.dataSource = self; collection.delegate = self
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.onCommit = { [weak self] in self?.chooseCurrentItem() }
        collection.setAccessibilityLabel("Space icons")
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = true
        view.addSubview(scroll)
        scrollObserver = NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification,
            object: scroll.contentView).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCategorySelection() }
        }

        footer.frame = NSRect(x: 11, y: 230, width: 250, height: 34)
        for category in SpaceEmojiCatalog.Category.allCases {
            let button = NSButton()
            button.frame = NSRect(x: CGFloat(category.rawValue) * 31 + 1, y: 5, width: 30, height: 26)
            button.title = ""; button.isBordered = false
            button.image = Self.templateImage(category.symbol, side: 14)
            button.contentTintColor = .secondaryLabelColor
            button.target = self; button.action = #selector(jumpToCategory(_:))
            button.tag = category.rawValue
            button.toolTip = category.title; button.setAccessibilityLabel(category.title)
            categoryButtons.append(button); footer.addSubview(button)
        }
        view.addSubview(footer)
        divider.boxType = .separator
        divider.frame = NSRect(x: 11, y: 228, width: 250, height: 1)
        view.addSubview(divider)
        empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.frame = NSRect(x: 11, y: 140, width: 250, height: 20)
        view.addSubview(empty)
        configureMode()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if mode == .emoji {
            view.window?.makeFirstResponder(search)
            if case .emoji(let glyph) = selected, let index = SpaceEmojiCatalog.index(of: glyph) {
                scrollTo(index)
            }
        }
    }

    @objc private func chooseGlyphMode() { setMode(Mode(rawValue: tabs.selectedSegment) ?? .emoji) }
    func setMode(_ newMode: Mode) {
        mode = newMode
        guard isViewLoaded else { return }
        tabs.selectedSegment = mode.rawValue
        configureMode()
        if mode == .emoji { view.window?.makeFirstResponder(search) }
        else { view.window?.makeFirstResponder(collection) }
    }
    private func configureMode() {
        search.isHidden = mode == .icon; footer.isHidden = mode == .icon; divider.isHidden = mode == .icon
        scroll.frame = NSRect(x: 11, y: mode == .emoji ? 84 : 47, width: 250, height: mode == .emoji ? 144 : 217)
        if let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = NSSize(width: 31, height: mode == .emoji ? 33 : 31)
            layout.invalidateLayout()
        }
        collection.selectionIndexPaths = []
        collection.reloadData()
        collection.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        empty.isHidden = mode == .icon || !displayedEmoji.isEmpty
        updateCategorySelection()
    }
    func searchFor(_ query: String) {
        displayedEmoji = SpaceEmojiCatalog.matching(query)
        if isViewLoaded {
            search.stringValue = query
            configureMode()
        }
    }
    func controlTextDidChange(_ obj: Notification) { searchFor(search.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard !displayedEmoji.isEmpty else { return true }
            collection.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
            view.window?.makeFirstResponder(collection)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if mode == .emoji, !displayedEmoji.isEmpty { chooseItem(at: 0) }
            return true
        }
        return false
    }
    @objc private func removeIcon() { onChoose(.automatic) }
    @objc private func jumpToCategory(_ sender: NSButton) {
        guard let category = SpaceEmojiCatalog.Category(rawValue: sender.tag) else { return }
        searchFor("")
        if let index = displayedEmoji.firstIndex(where: { $0.category == category }) { scrollTo(index) }
        view.window?.makeFirstResponder(search)
    }
    private func scrollTo(_ index: Int) {
        // scrollToItems(.top) adds AppKit's item reveal margin. Move the
        // clip view to the exact row boundary so no preceding row peeks in.
        collection.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index / 8) * 33))
        scroll.reflectScrolledClipView(scroll.contentView)
        updateCategorySelection()
    }
    private func updateCategorySelection() {
        guard mode == .emoji else { return }
        // Collection reuse lags the bounds notification by one layout pass.
        // Calculate the visible category from the viewport, not stale cells.
        let viewport = scroll.contentView.bounds
        let index = Int(max(0, (viewport.minY + viewport.height / 2) / 33)) * 8
        let category = displayedEmoji.indices.contains(index) ? displayedEmoji[index].category : nil
        for button in categoryButtons {
            let selected = category?.rawValue == button.tag
            button.contentTintColor = selected ? .labelColor : .secondaryLabelColor
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
    }
    private static func templateImage(_ name: String, side: CGFloat) -> NSImage? {
        guard let image = SpaceSymbols.image(named: name)?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: side, height: side)
        return image
    }
    private func chooseCurrentItem() {
        if let path = collection.selectionIndexPaths.first { chooseItem(at: path.item) }
    }
    func chooseItem(at index: Int) {
        switch mode {
        case .emoji:
            guard displayedEmoji.indices.contains(index) else { return }
            onChoose(.emoji(displayedEmoji[index].glyph))
        case .icon:
            guard SpaceSymbols.choices.indices.contains(index) else { return }
            onChoose(.symbol(SpaceSymbols.choices[index].storedName))
        }
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        mode == .emoji ? displayedEmoji.count : SpaceSymbols.choices.count
    }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! GlyphItem
        let index = indexPath.item
        let icon: SpaceIcon, label: String, chosen: Bool
        switch mode {
        case .emoji:
            let entry = displayedEmoji[index]
            icon = .emoji(entry.glyph); label = entry.name
            if case .emoji(let glyph) = selected {
                chosen = SpaceEmojiCatalog.normalized(glyph) == SpaceEmojiCatalog.normalized(entry.glyph)
            } else { chosen = false }
        case .icon:
            let entry = SpaceSymbols.choices[index]
            icon = .symbol(entry.storedName); label = entry.title
            chosen = selected == icon
        }
        item.configure(icon: icon, label: label, chosen: chosen) { [weak self] in self?.chooseItem(at: index) }
        return item
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
    private final class GlyphCollection: NSCollectionView {
        var onCommit: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 { onCommit?() }
            else { super.keyDown(with: event) }
        }
    }
    private final class GlyphItem: NSCollectionViewItem {
        private let button = GlyphButton()
        override func loadView() {
            view = NSView()
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 30),
                button.heightAnchor.constraint(equalToConstant: 30)
            ])
        }
        override var isSelected: Bool { didSet { button.keyboardSelected = isSelected } }
        func configure(icon: SpaceIcon, label: String, chosen: Bool, action: @escaping () -> Void) {
            _ = view
            let side: CGFloat = if case .emoji = icon { 22 } else { 14 }
            button.image = icon.image(color: .gray, title: label, side: side)
            button.chosen = chosen
            button.keyboardSelected = isSelected
            button.run = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.setAccessibilityValue(chosen ? "Selected" : "")
        }
        override func prepareForReuse() { super.prepareForReuse(); button.run = nil }
    }
    private final class GlyphButton: NSButton {
        var run: (() -> Void)?
        var chosen = false { didSet { needsDisplay = true } }
        var keyboardSelected = false { didSet { needsDisplay = true } }
        private var hovering = false { didSet { needsDisplay = true } }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            title = ""; isBordered = false
            imagePosition = .imageOnly
            imageScaling = .scaleProportionallyDown
            target = self; action = #selector(choose)
        }
        required init?(coder: NSCoder) { fatalError("Created in code only") }
        @objc private func choose() { run?() }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }
        override func draw(_ dirtyRect: NSRect) {
            if chosen || keyboardSelected || hovering {
                NSColor.labelColor.withAlphaComponent(keyboardSelected ? 0.16 : 0.09).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            }
            super.draw(dirtyRect)
        }
    }
}
