// Modified for Barc: Arc's compact tab menus and active/background split actions, 2026-10-25.
import AppKit

@MainActor
enum TabOptionsMenu {
    enum Action {
        case copyLink, icon, rename, mute, customize, split, duplicate, newSpace
        case archive, archiveOther, archiveAbove, archiveBelow, removePin, replacePinnedURL, editPinnedURL
        case move(UUID)
    }
    static func make(retained: Bool, muted: Bool, canMute: Bool, canRemove: Bool, canSplit: Bool, addingSplit: Bool,
                     canReplacePinnedURL: Bool, canCustomize:Bool, owner: Space?, destinations: [Space],
                     canArchiveOther: Bool, canArchiveAbove: Bool, canArchiveBelow: Bool,
                     perform: @escaping (Action) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        @discardableResult
        func add(_ title: String, _ action: Action, to parent: NSMenu? = nil, alternate: Bool = false, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(Target.run(_:)), keyEquivalent: "")
            let target = Target { perform(action) }
            item.target = target; item.representedObject = target
            item.isEnabled = enabled
            item.isAlternate = alternate
            if alternate { item.keyEquivalentModifierMask = .option }
            (parent ?? menu).addItem(item)
            return item
        }
        let copy = add("Copy Link", .copyLink)
        copy.keyEquivalent = "c";copy.keyEquivalentModifierMask = [.command,.shift]
        menu.addItem(.separator())
        add("Change Icon…", .icon)
        add("Rename…", .rename)
        add(muted ? "Unmute" : "Mute", .mute, enabled: canMute)
        if canCustomize { add("Customize Page…", .customize) }
        if retained {
            let edit = NSMenuItem(title: "Edit Pinned Page", action: nil, keyEquivalent: "")
            let options = NSMenu(); options.autoenablesItems = false
            add("Replace Pinned URL with Current", .replacePinnedURL, to: options, enabled: canReplacePinnedURL)
            add("Edit…", .editPinnedURL, to: options)
            edit.submenu = options; menu.addItem(edit)
        }
        menu.addItem(.separator())
        add(addingSplit ? "Add Split View" : "Open in Split View", .split, enabled: canSplit)
        add("Duplicate", .duplicate)
        let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let spaces = NSMenu(); spaces.autoenablesItems = false
        for candidate in destinations {
            let item = add(candidate.name, .move(candidate.id), to: spaces)
            item.state = candidate === owner ? .on : .off
            item.image = candidate.menuImage()
        }
        spaces.addItem(.separator())
        add("New Space…", .newSpace, to: spaces)
        move.submenu = spaces; menu.addItem(move)
        menu.addItem(.separator())
        if retained { add("Remove Pin", .removePin, enabled: canRemove) }
        else {
            add("Archive Tab", .archive, enabled: canRemove)
            add("Archive Other Tabs", .archiveOther, alternate: true, enabled: canArchiveOther)
            add("Archive Tabs Below", .archiveBelow, enabled: canArchiveBelow)
            add("Archive Tabs Above", .archiveAbove, alternate: true, enabled: canArchiveAbove)
        }
        return menu
    }
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run(_ sender: Any?) { action() }
    }
}
