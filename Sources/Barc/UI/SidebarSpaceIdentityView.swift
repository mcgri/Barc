// Modified for Barc: Arc's Space label, hover menu and inline rename, 2026-10-24.
import AppKit

@MainActor
final class SidebarSpaceIdentityView: NSView {
    let nameButton: MenuLabelButton
    let moreButton = IconButton(symbolName: "ellipsis", label: "Space Options", side: 24, symbolSize: 14)
    private var tracking: NSTrackingArea?
    private var hovered = false

    init(nameButton: MenuLabelButton) {
        self.nameButton = nameButton
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameButton)
        addSubview(moreButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            nameButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -2),
            nameButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3)
        ])
        moreButton.setClickHandler { [weak self] in
            guard let self else { return }
            if nameButton.isRenaming { nameButton.finishRenaming(commit: true); return }
            guard let menu = nameButton.menuProvider?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY), in: moreButton)
        }
        nameButton.onRenameStateChange = { [weak self] editing in
            guard let self else { return }
            moreButton.setSymbol(editing ? "checkmark" : "ellipsis", label: editing ? "Done" : "Space Options")
            refreshVisibility()
        }
        refreshVisibility()
    }

    required init?(coder: NSCoder) { fatalError("SidebarSpaceIdentityView is created in code only") }
    override func updateTrackingAreas() { super.updateTrackingAreas(); tracking = installHoverTracking(replacing: tracking) }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshVisibility() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshVisibility() }

    private func refreshVisibility() {
        moreButton.alphaValue = hovered || nameButton.isRenaming ? 1 : 0
    }
}
