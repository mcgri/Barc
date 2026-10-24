// Modified for Barc: Library overview of the real Spaces and their sidebar tabs, 2026-10-24.
import AppKit
import Combine

@MainActor
final class LibrarySpacesView: NSView {
    var onOpenTab: ((Space, Tab) -> Void)?
    var onNewTab: ((Space) -> Void)?
    var onNewSpace: (() -> Void)?
    var menuProvider: ((Space, NSView) -> NSMenu)?
    private let session: BrowserSession
    private let scroll = NSScrollView()
    private let strip = NSStackView()
    private let material = NSVisualEffectView()
    private let shade = ChromeMaterialShadeView()
    private let tint = TintView()
    private var subscription: AnyCancellable?
    private var cards: [UUID: LibrarySpaceCard] = [:]
    private var order: [UUID] = []

    init(session: BrowserSession) {
        self.session = session
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material.material = .sidebar; material.blendingMode = .behindWindow; material.state = .active
        for view in [material, shade, tint] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)])
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = true
        scroll.horizontalScrollElasticity = .automatic
        strip.orientation = .horizontal; strip.alignment = .top; strip.spacing = 16
        strip.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(strip); scroll.documentView = document; addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            strip.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            strip.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            strip.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            strip.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        subscription = session.changes.sink { [weak self] change in
            switch change { case .spaces, .structure, .tabs: self?.reload(); default: break }
        }
        reload()
        setAccessibilityRole(.group); setAccessibilityLabel("Spaces Library")
    }
    required init?(coder: NSCoder) { fatalError("LibrarySpacesView is created in code only") }
    func reload() {
        let space = session.activeSpace
        tint.wash = space.wash(for: space.activeTab); tint.gradientWash = space.washGradient(for: space.activeTab)
        tint.grainAmount = 0
        shade.strength = LibraryMetrics.materialStrength
        shade.isHidden = space.activeImportedChrome?.usesLightMaterial != true
        material.appearance = space.activeImportedChrome.map { NSAppearance(named: $0.usesLightMaterial ? .aqua : .darkAqua) } ?? nil
        let nextOrder = session.spaces.map(\.id)
        if order == nextOrder {
            for space in session.spaces { cards[space.id]?.reload() }
            return
        }
        order = nextOrder
        let desired = Set(session.spaces.map(\.id))
        for (id, card) in cards where !desired.contains(id) { strip.removeArrangedSubview(card); card.removeFromSuperview(); cards[id] = nil }
        for arranged in strip.arrangedSubviews { strip.removeArrangedSubview(arranged); arranged.removeFromSuperview() }
        for space in session.spaces {
            let card = cards[space.id] ?? LibrarySpaceCard(space: space, session: session)
            cards[space.id] = card
            card.onOpenTab = { [weak self, weak space] tab in if let space { self?.onOpenTab?(space, tab) } }
            card.onNewTab = { [weak self, weak space] in if let space { self?.onNewTab?(space) } }
            card.menuProvider = { [weak self, weak space] anchor in guard let space else { return nil }; return self?.menuProvider?(space, anchor) }
            card.reload()
            strip.addArrangedSubview(card)
            card.heightAnchor.constraint(equalTo: strip.heightAnchor).isActive = true
        }
        let add = LibraryNewSpaceButton { [weak self] in self?.onNewSpace?() }
        strip.addArrangedSubview(add)
        add.heightAnchor.constraint(equalTo: strip.heightAnchor).isActive = true
    }
}

@MainActor
private final class LibrarySpaceCard: NSView, NSTextFieldDelegate {
    var onOpenTab: ((Tab) -> Void)?
    var onNewTab: (() -> Void)?
    var menuProvider: ((NSView) -> NSMenu?)?
    private let space: Space
    private let session: BrowserSession
    private let name = NSTextField()
    private let icon = NSImageView()
    private let more = IconButton(symbolName: "pencil", label: "Space Options", side: 22, symbolSize: 12)
    private let scroll = NSScrollView()
    private let rows = LibraryFlippedStack()
    private let grain = ChromeGrainView()

    init(space: Space, session: BrowserSession) {
        self.space = space; self.session = session
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; layer?.cornerRadius = 10; layer?.masksToBounds = true
        widthAnchor.constraint(equalToConstant: 240).isActive = true
        grain.translatesAutoresizingMaskIntoConstraints = false; addSubview(grain)
        icon.translatesAutoresizingMaskIntoConstraints = false; icon.imageScaling = .scaleProportionallyDown
        name.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 13, weight: .semibold); name.isBezeled = false; name.drawsBackground = false
        name.delegate = self; name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        name.setAccessibilityLabel("Space name")
        more.setClickHandler { [weak self] in
            guard let self, let menu = menuProvider?(more) else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY), in: more)
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.automaticallyAdjustsContentInsets = false
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows
        let add = IconButton(symbolName: "plus", label: "New Tab in \(space.name)", side: 26, symbolSize: 15) { [weak self] in self?.onNewTab?() }
        [icon, name, more, scroll, add].forEach(addSubview)
        NSLayoutConstraint.activate([
            grain.leadingAnchor.constraint(equalTo: leadingAnchor), grain.trailingAnchor.constraint(equalTo: trailingAnchor),
            grain.topAnchor.constraint(equalTo: topAnchor), grain.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), icon.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            name.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -4),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), more.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -6),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            add.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), add.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("LibrarySpaceCard is created in code only") }
    func reload() {
        if name.currentEditor() == nil { name.stringValue = space.name }
        icon.image = space.dotImage(side: 16)
        let dark = space.activeImportedChrome.map { !$0.usesDarkText } ?? (space.look.appearance == .dark)
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let ground = NSColor(srgbRed: 0.72, green: 0.72, blue: 0.72, alpha: 1)
        let wash = space.wash?.usingColorSpace(.sRGB)
        layer?.backgroundColor = wash.map { ground.blended(withFraction: $0.alphaComponent, of: $0.withAlphaComponent(1))?.cgColor ?? ground.cgColor } ?? ground.cgColor
        grain.amount = space.chromeGrain
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        let visible = space.listedTabs.filter { !(StartPage.isStartPage($0.url) && $0.importedSourceID == nil && $0.customName == nil) }
        for row in FolderRowPlan.rows(groups: space.groups, tabs: visible, activeTabID: space.activeTabID) {
            switch row {
            case .folder(let group, let depth, _):
                let button = LibrarySpaceRow(title: group.name, image: SidebarFolderGlyph.image(tint: space.color, badge: group.badgeIcon), depth: depth) { [weak self, weak group] in
                    guard let self, let group else { return }; session.toggleCollapsed(group)
                }
                append(button)
            case .tab(let tab, let depth, _):
                let image = tab.restoredFavicon.flatMap { $0.matches(tab.url) ? NSImage(data: $0.data) : nil }
                    ?? FaviconService.shared.cachedImage(for: tab.url)
                append(LibrarySpaceRow(title: tab.displayTitle, image: image, depth: depth) { [weak self, weak tab] in if let tab { self?.onOpenTab?(tab) } })
            }
        }
        setAccessibilityLabel(space.name)
    }
    private func append(_ row: NSView) { rows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
    func controlTextDidEndEditing(_ notification: Notification) { session.rename(space, to: name.stringValue); name.stringValue = space.name }
}

@MainActor
private final class LibrarySpaceRow: NSButton {
    private let invoke: () -> Void
    init(title: String, image: NSImage?, depth: Int, invoke: @escaping () -> Void) {
        self.invoke = invoke
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false; self.title = ""; target = self; action = #selector(open)
        let glyph = NSImageView(); glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyDown
        glyph.image = image ?? FaviconImageView.placeholder
        if image == nil { glyph.contentTintColor = .tertiaryLabelColor }
        let label = NSTextField(labelWithString: title); label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        addSubview(glyph); addSubview(label)
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 38),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7 + CGFloat(depth) * 12), glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16), glyph.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityLabel(title); toolTip = title
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }
    @objc private func open() { invoke() }
}

private final class LibraryFlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class LibraryNewSpaceButton: NSButton {
    private let invoke: () -> Void
    init(invoke: @escaping () -> Void) {
        self.invoke = invoke; super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title = "New Space"; image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil); imagePosition = .imageAbove
        isBordered = false; target = self; action = #selector(create)
        widthAnchor.constraint(equalToConstant: 140).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }
    @objc private func create() { invoke() }
}
