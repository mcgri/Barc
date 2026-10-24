// Modified for Barc: compact 8-by-3 folder icon chooser, 2026-10-24.
import AppKit

@MainActor
final class FolderIconPicker: NSViewController {
    private let onChoose: (FolderIcon) -> Void
    private let selected: FolderIcon

    init(selected: FolderIcon, onChoose: @escaping (FolderIcon) -> Void) {
        self.selected = selected
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 270, height: 144)
    }

    required init?(coder: NSCoder) { fatalError("Created in code only") }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        let title = NSTextField(labelWithString: "Icon")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        let buttons = FolderSymbols.choices.enumerated().map { index, choice in
            let button = NSButton()
            button.setButtonType(.momentaryChange)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.title = ""
            button.imagePosition = .imageOnly
            let symbol = FolderSymbols.image(named: choice.storedName)
            // Solid gray artwork stays neutral over a colorful popover. A
            // template button image inherits the material's vibrant tint.
            let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                symbol?.draw(in: rect)
                NSColor.gray.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            image.isTemplate = false
            button.image = image
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = choice.title
            button.setAccessibilityLabel(choice.title)
            button.setAccessibilityValue(selected == .symbol(choice.storedName) ? "Selected" : "")
            button.target = self
            button.action = #selector(choose(_:))
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24)
            ])
            return button
        }
        let grid = NSGridView(views: stride(from: 0, to: buttons.count, by: 8).map { start in
            Array(buttons[start..<min(start + 8, buttons.count)])
        })
        grid.rowSpacing = 7
        grid.columnSpacing = 7
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 13),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 45),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    @objc private func choose(_ sender: NSButton) {
        guard FolderSymbols.choices.indices.contains(sender.tag) else { return }
        onChoose(.symbol(FolderSymbols.choices[sender.tag].storedName))
    }
}
