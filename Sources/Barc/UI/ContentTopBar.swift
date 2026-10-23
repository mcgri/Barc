// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit

/// One trailing action in the top bar.
///
/// The trailing cluster is caller-supplied rather than hard-coded because
/// other browsers' own buttons there are features Barc does not have.
/// Inventing lookalikes would be fake UI; this way the bar shows exactly the
/// commands Barc actually has.
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
    let sidebarToggle = IconButton(symbolName: "sidebar.leading", label: "Toggle Sidebar")
    let backButton = IconButton(symbolName: "chevron.left", label: "Back")
    let forwardButton = IconButton(symbolName: "chevron.right", label: "Forward")
    let reloadButton = IconButton(symbolName: "arrow.clockwise", label: "Reload")
    let addressField = AddressField()

    private let navigation = WrappingControlsView()
    private let actions = WrappingControlsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        navigation.setButtons([sidebarToggle, backButton, forwardButton, reloadButton])
        let stack = NSStackView(views: [navigation, addressField, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Style.Metrics.sidebarInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            navigation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            addressField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Browser controls")
    }

    required init?(coder: NSCoder) {
        fatalError("ContentTopBar is created in code only")
    }

    func setActions(_ newActions: [TopBarAction]) {
        actions.setButtons(newActions.map {
            IconButton(symbolName: $0.symbolName, label: $0.label, onClick: $0.handler)
        })
        actions.isHidden = newActions.isEmpty
    }

    func actionButton(labelled label: String) -> NSView? {
        actions.buttons.first { $0.accessibilityLabel() == label }
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
    private var height: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        height = heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("Created in code only") }

    func setButtons(_ buttons: [IconButton]) {
        for button in self.buttons { button.removeFromSuperview() }
        self.buttons = buttons
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.autoresizingMask = [.maxXMargin, .minYMargin]
            addSubview(button)
        }
        needsLayout = true
        arrangeButtons()
    }

    override func layout() {
        super.layout()
        arrangeButtons()
    }

    private func arrangeButtons() {
        let gap = Style.Metrics.iconButtonSpacing
        let side = Style.Metrics.iconButtonSide
        let width = bounds.width > 0 ? bounds.width : 200
        let columns = max(1, Int((width + gap) / (side + gap)))
        let rowCount = (buttons.count + columns - 1) / columns
        let totalHeight = CGFloat(rowCount) * (side + gap) - (rowCount > 0 ? gap : 0)
        if height.constant != totalHeight { height.constant = totalHeight }
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index % columns) * (side + gap),
                                  y: totalHeight - CGFloat(index / columns + 1) * (side + gap) + gap,
                                  width: side, height: side)
        }
    }
}
