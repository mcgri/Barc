// Modified for Barc: expose launcher suggestions and selection as a native accessibility table, 2026-10-24.
import AppKit

/// The stack keeps ordinary view layout while presenting the same single
/// selection list to accessibility clients as Arc's suggestions table.
@MainActor
final class CommandResultsView: NSStackView {
    var onSelect: ((Int?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.table)
        setAccessibilityLabel("Suggestions")
        setAccessibilityColumnCount(1)
    }

    required init?(coder: NSCoder) { fatalError("Created in code only") }

    override func accessibilityChildren() -> [Any]? { arrangedSubviews }
    override func accessibilityRows() -> [Any]? { arrangedSubviews }
    override func accessibilityVisibleRows() -> [Any]? { arrangedSubviews }
    override func accessibilityRowCount() -> Int { arrangedSubviews.count }
    override func accessibilitySelectedRows() -> [Any]? {
        arrangedSubviews.compactMap { $0 as? CommandRowView }.filter(\.isSelected)
    }
    override func setAccessibilitySelectedRows(_ rows: [Any]?) {
        guard let first = rows?.first else { onSelect?(nil); return }
        guard let row = first as? CommandRowView,
              let index = arrangedSubviews.firstIndex(where: { $0 === row }) else { return }
        onSelect?(index)
    }
}
