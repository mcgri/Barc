// Modified for Barc: compact Arc-style Home, Space dock and add controls, 2026-10-24.
// Modified for Barc: restore the visible performance gauge, 2026-10-25.
import AppKit

@MainActor
final class SidebarFooterView: NSView {
    static let height: CGFloat = SpaceDockLayout.height
    var canDropOnSpace:((UUID,NSPasteboard,NSDragOperation) -> Bool)?
    var onDropOnSpace:((UUID,NSPasteboard,NSDragOperation) -> Bool)?
    var onSelectSpace: ((UUID) -> Void)?
    var onChangeIcon: ((UUID, IconMenu.Choice) -> Void)?
    var spaceMenuProvider: ((UUID, NSView) -> NSMenu)?
    var addMenuProvider: (() -> NSMenu)?
    var onOpenLibrary: (() -> Void)?
    let homeButton = IconButton(symbolName: "archivebox.fill", label: "Home", side: 24, symbolSize: 18)
    let addButton = IconButton(symbolName: "plus", label: "Add", side: 24, symbolSize: 16)
    private let dock = SpaceDockView()
    private let performanceSlot = NSView()
    private var performanceWidth: NSLayoutConstraint!
    private var leadingActions: [(String, IconButton)] = []
    private var trailingActions: [(String, IconButton)] = []
    var isShowingArchive = false { didSet { homeButton.isActive = isShowingArchive } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        homeButton.setGlyph(SidebarHomeGlyph.image(),label:"Home")
        addButton.setGlyph(SidebarAddGlyph.image(),label:"Add")
        addSubview(homeButton)
        performanceSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(performanceSlot)
        addSubview(dock)
        addSubview(addButton)
        homeButton.setClickHandler { [weak self] in
            guard let self else { return }
            if let onOpenLibrary { onOpenLibrary(); return }
            makeHomeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: homeButton.bounds.maxY), in: homeButton)
        }
        addButton.setClickHandler { [weak self] in
            guard let self, let menu = addMenuProvider?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.maxY), in: addButton)
        }
        dock.canDropOnSpace = { [weak self] in self?.canDropOnSpace?($0,$1,$2) == true }
        dock.onDropOnSpace = { [weak self] in self?.onDropOnSpace?($0,$1,$2) == true }
        dock.onSelect = { [weak self] in self?.onSelectSpace?($0) }
        dock.onChangeIcon = { [weak self] in self?.onChangeIcon?($0, $1) }
        dock.menuProvider = { [weak self] id, anchor in self?.spaceMenuProvider?(id, anchor) ?? NSMenu() }
        performanceWidth = performanceSlot.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            performanceWidth,
            homeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            homeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor,constant:-12),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            performanceSlot.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor),
            performanceSlot.topAnchor.constraint(equalTo: topAnchor),
            performanceSlot.bottomAnchor.constraint(equalTo: bottomAnchor),
            dock.leadingAnchor.constraint(equalTo: performanceSlot.trailingAnchor),
            dock.trailingAnchor.constraint(equalTo: addButton.leadingAnchor),
            dock.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }

    func setLeadingActions(_ actions: [TopBarAction]) {
        performanceSlot.subviews.forEach { $0.removeFromSuperview() }
        leadingActions = controls(actions)
        let button = leadingActions.first { $0.0 == "Task Manager" }?.1
        performanceWidth.constant = button == nil ? 0 : 24
        if let button {
            performanceSlot.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: performanceSlot.leadingAnchor),
                button.centerYAnchor.constraint(equalTo: performanceSlot.centerYAnchor)
            ])
        }
    }
    func setTrailingActions(_ actions: [TopBarAction]) { trailingActions = controls(actions) }
    private func controls(_ actions: [TopBarAction]) -> [(String, IconButton)] {
        actions.map {
            ($0.label, IconButton(symbolName: $0.symbolName, label: $0.label,
                                 side: $0.label == "Task Manager" ? 24 : Style.Metrics.iconButtonSide,
                                 symbolSize: $0.label == "Task Manager" ? 16 : nil,
                                 onClick: $0.handler))
        }
    }
    func actionButton(labelled label: String) -> NSView? {
        (leadingActions + trailingActions).first { $0.0 == label }?.1
    }
    func actionAnchor(labelled label: String) -> NSView? {
        guard let button = actionButton(labelled: label) else { return nil }
        return button.superview == nil ? homeButton : button
    }
    func makeHomeMenu() -> NSMenu {
        let menu = NSMenu(title: "Home")
        menu.autoenablesItems = false
        for (_, button) in leadingActions + trailingActions {
            let count = button.badgeCount
            let name = button.accessibilityLabel() ?? ""
            let item = NSMenuItem(title: count > 0 ? "\(name) (\(count))" : name,
                                  action: button.action, keyEquivalent: "")
            item.target = button.target
            item.image = button.symbolImage
            item.isEnabled = button.isEnabled
            item.state = button.isActive ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
    func showSpaces(_ items: [SpaceDockItem], selectedID: UUID?) { dock.show(items, selectedID: selectedID) }
}
