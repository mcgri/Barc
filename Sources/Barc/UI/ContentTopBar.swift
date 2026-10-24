// Modified for Barc: sidebar navigation with utility actions in one menu, 2026-10-24.
import AppKit

/// A caller-supplied action in the page utility menu.
struct TopBarAction {
    let symbolName: String
    let label: String
    let handler: () -> Void

    init(symbolName: String, label: String, handler: @escaping () -> Void) {
        self.symbolName = symbolName
        self.label = label
        self.handler = handler
    }
}

/// Browser navigation and page actions, hosted at the top of the sidebar.
@MainActor
final class ContentTopBar: NSView {
    let sidebarToggle = IconButton(symbolName: "sidebar.leading", label: "Toggle Sidebar", side: 24, symbolSize: 16)
    let backButton = IconButton(symbolName: "arrow.left", label: "Back", side: 24, symbolSize: 16)
    let forwardButton = IconButton(symbolName: "arrow.right", label: "Forward", side: 24, symbolSize: 16)
    let reloadButton = IconButton(symbolName: "arrow.clockwise", label: "Reload", side: 24, symbolSize: 16)
    let utilitiesButton = IconButton(symbolName: "ellipsis", label: "Page Utilities", side: 24)
    let addressField = AddressField()

    private let navigation = WrappingControlsView()
    private var navigationWidth: NSLayoutConstraint!
    private var contentStack: NSStackView!
    /// Retain each action's existing state and handler without putting its button in the sidebar.
    private var utilityActions: [(label: String, button: IconButton)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        navigation.setButtons([sidebarToggle, utilitiesButton, backButton, forwardButton, reloadButton])
        utilitiesButton.isEnabled = false
        utilitiesButton.setClickHandler { [weak self] in self?.showUtilitiesMenu() }
        let stack = NSStackView(views: [navigation, addressField])
        contentStack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        navigationWidth = navigation.widthAnchor.constraint(equalTo: stack.widthAnchor)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Style.Metrics.sidebarInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            navigationWidth,
            addressField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Browser controls")
    }

    required init?(coder: NSCoder) {
        fatalError("ContentTopBar is created in code only")
    }

    func takeNavigationRow() -> NSView {
        navigationWidth.isActive = false
        contentStack.removeArrangedSubview(navigation)
        navigation.removeFromSuperview()
        return navigation
    }

    func setActions(_ newActions: [TopBarAction]) {
        utilityActions = newActions.map {
            ($0.label, IconButton(symbolName: $0.symbolName, label: $0.label, onClick: $0.handler))
        }
        utilitiesButton.isEnabled = !newActions.isEmpty
    }

    func actionButton(labelled label: String) -> NSView? {
        utilityActions.first { $0.label == label }?.button
    }

    /// Popovers from menu actions attach to the visible ellipsis, not to an undisplayed control.
    func actionAnchor(labelled label: String) -> NSView? {
        actionButton(labelled: label) == nil ? nil : utilitiesButton
    }

    func makeUtilitiesMenu() -> NSMenu {
        let menu = NSMenu(title: "Page Utilities")
        menu.autoenablesItems = false
        for (_, button) in utilityActions {
            let item = NSMenuItem(title: button.accessibilityLabel() ?? "", action: button.action, keyEquivalent: "")
            item.target = button.target
            item.image = button.symbolImage
            item.isEnabled = button.isEnabled
            item.state = button.isActive ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func showUtilitiesMenu() {
        makeUtilitiesMenu().popUp(positioning: nil,
                                  at: NSPoint(x: 0, y: utilitiesButton.bounds.minY),
                                  in: utilitiesButton)
    }

    func update(canGoBack: Bool, canGoForward: Bool, isLoading: Bool, hasPage: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        reloadButton.isEnabled = hasPage
        reloadButton.setSymbol(isLoading ? "xmark" : "arrow.clockwise",
                               label: isLoading ? "Stop Loading" : "Reload")
    }
}

/// Keeps every control reachable as the sidebar is resized, without widening it.
@MainActor
private final class WrappingControlsView: NSView {
    private(set) var buttons: [IconButton] = []
    private var origins: [(x: NSLayoutConstraint, y: NSLayoutConstraint)] = []
    private var height: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        autoresizesSubviews = false
        height = heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("Created in code only") }

    func setButtons(_ buttons: [IconButton]) {
        NSLayoutConstraint.deactivate(origins.flatMap { [$0.x, $0.y] })
        origins = []
        for button in self.buttons { button.removeFromSuperview() }
        self.buttons = buttons
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            let x = button.leadingAnchor.constraint(equalTo: leadingAnchor)
            let y = button.topAnchor.constraint(equalTo: topAnchor)
            origins.append((x, y))
            NSLayoutConstraint.activate([x, y])
        }
        needsLayout = true
        arrangeButtons()
    }

    override func layout() {
        super.layout()
        arrangeButtons()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = bounds.size != newSize
        super.setFrameSize(newSize)
        if changed, height != nil { arrangeButtons() }
    }

    private func arrangeButtons() {
        let gap: CGFloat = 3
        let side: CGFloat = 24
        let width = bounds.width > 0 ? bounds.width : 200
        let columns = max(1, Int((width + gap) / (side + gap)))
        let rowCount = (buttons.count + columns - 1) / columns
        let totalHeight = CGFloat(rowCount) * (side + gap) - (rowCount > 0 ? gap : 0)
        if height.constant != totalHeight { height.constant = totalHeight }
        for (index, origin) in origins.enumerated() {
            origin.x.constant = CGFloat(index % columns) * (side + gap)
            origin.y.constant = CGFloat(index / columns) * (side + gap)
        }
        if buttons.count == 5, columns >= 5 {
            // Keep the sidebar toggle and utility menu together, leaving Arc's
            // back/forward/reload positions across the remaining top band.
            // Narrow sidebars still use the wrapped layout above.
            let last = max(4 * side, width - side - 11)
            let navigationStep = (last - 2 * side) / 2
            for (index, origin) in origins.enumerated() {
                origin.x.constant = index < 2 ? CGFloat(index) * side : 2 * side + CGFloat(index - 2) * navigationStep
            }
        }
    }
}
