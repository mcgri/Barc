// Modified for Barc: context menus use the sidebar's own row appearance, 2026-10-24.
import AppKit

@MainActor
final class SidebarTableView: NSTableView {
    var menuForRow: ((Int) -> NSMenu)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menuForRow else { return super.menu(for: event) }
        // NSTableView's implementation adds a rectangular contextual highlight
        // around the clicked row. The sidebar cells already draw their hover
        // and selection, so ask for the menu without that additional outline.
        let point = convert(event.locationInWindow, from: nil)
        return menuForRow(row(at: point))
    }
}
