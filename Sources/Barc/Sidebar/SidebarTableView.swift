// Modified for Barc: expose the inline folder name editor alongside table rows, 2026-10-24.
import AppKit

@MainActor
final class SidebarTableView: NSTableView {
    weak var inlineNameEditor: FolderNameEditor?

    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        // NSTableView synthesizes its row hierarchy instead of exposing all
        // subviews. Include the editor that deliberately outlives row reuse.
        if let editor = inlineNameEditor, editor.superview === self,
           !children.contains(where: { ($0 as AnyObject) === editor }) {
            children.append(editor)
        }
        return children
    }
}
