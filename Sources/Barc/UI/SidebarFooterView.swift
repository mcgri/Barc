// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit

/// Browser utility buttons above the Space icon dock at the foot of the sidebar.
@MainActor
final class SidebarFooterView: NSView {
    static let height = Style.Metrics.footerHeight + SpaceDockLayout.height
    var onSelectSpace: ((UUID) -> Void)?
    var onChangeIcon: ((UUID, IconMenu.Choice) -> Void)?

    private let leadingSlot = NSStackView()
    private let trailingSlot = NSStackView()
    private let dock = SpaceDockView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        for slot in [leadingSlot, trailingSlot] {
            slot.orientation = .horizontal
            slot.spacing = Style.Metrics.iconButtonSpacing
            slot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(slot)
        }
        dock.onSelect = { [weak self] id in self?.onSelectSpace?(id) }
        dock.onChangeIcon = { [weak self] id, choice in self?.onChangeIcon?(id, choice) }
        addSubview(dock)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            leadingSlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Style.Metrics.sidebarInset),
            leadingSlot.centerYAnchor.constraint(equalTo: topAnchor, constant: Style.Metrics.footerHeight / 2),
            trailingSlot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Style.Metrics.sidebarInset),
            trailingSlot.centerYAnchor.constraint(equalTo: leadingSlot.centerYAnchor),
            dock.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Style.Metrics.sidebarInset),
            dock.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Style.Metrics.sidebarInset),
            dock.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarFooterView is created in code only")
    }

    func setLeadingActions(_ actions: [TopBarAction]) { fill(leadingSlot, with: actions) }
    func setTrailingActions(_ actions: [TopBarAction]) { fill(trailingSlot, with: actions) }

    /// The button for one of the actions, to hang a popover on. Nil until the
    /// actions have been set, which is why a caller anchors through a closure
    /// rather than holding the view.
    func actionButton(labelled label: String) -> NSView? {
        for slot in [leadingSlot, trailingSlot] {
            if let button = slot.arrangedSubviews.first(where: { $0.accessibilityLabel() == label }) {
                return button
            }
        }
        return nil
    }

    func showSpaces(_ items: [SpaceDockItem], selectedID: UUID?) {
        dock.show(items, selectedID: selectedID)
    }

    private func fill(_ stack: NSStackView, with actions: [TopBarAction]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for action in actions {
            stack.addArrangedSubview(
                IconButton(symbolName: action.symbolName, label: action.label, onClick: action.handler)
            )
        }
    }
}
