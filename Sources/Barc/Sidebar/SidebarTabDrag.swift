// Modified for Barc: identify a dragged sidebar tab without relying on its changing row index, 2026-10-24.
import AppKit

enum SidebarTabDrag {
    static let type = NSPasteboard.PasteboardType("io.github.mcgri.Barc.sidebarTabID")

    static func id(in pasteboard: NSPasteboard) -> UUID? {
        pasteboard.string(forType: type).flatMap(UUID.init(uuidString:))
    }
}
