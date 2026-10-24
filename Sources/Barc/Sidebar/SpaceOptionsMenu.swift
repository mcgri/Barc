// Modified for Barc: Space actions shared by the header and dock, 2026-10-24.
import AppKit

@MainActor
enum SpaceOptionsMenu {
    enum Action: Equatable {
        case icon, rename, theme, newFolder, github, manage, delete, newProfile
        case profile(UUID)
        case exportInto(UUID)
    }

    static func make(canDelete: Bool, hasGitHubFolder: Bool, profiles: [BrowserProfile] = [],
                     selectedProfileID: UUID? = nil, allowsProfileChange: Bool = true,
                     exportSource: Space? = nil, exportDestinations: [Space] = [],
                     perform: @escaping (Action) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Space Options")
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Action, to menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(Target.run(_:)), keyEquivalent: "")
            let target = Target { perform(action) }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
            return item
        }
        _ = add("Change Space Icon…", .icon, to: menu)
        _ = add("Rename Space…", .rename, to: menu)
        _ = add("Edit Theme Color…", .theme, to: menu)
        let setProfile = NSMenuItem(title: "Set Profile", action: nil, keyEquivalent: "")
        let choices = NSMenu(title: "Set Profile"); choices.autoenablesItems = false
        for profile in profiles.filter({ !$0.identity.isPrivate }).sorted(by: {
            if ($0.identity == .standard) != ($1.identity == .standard) { return $0.identity == .standard }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }) {
            add(profile.name, .profile(profile.id), to: choices).state = profile.id == selectedProfileID ? .on : .off
        }
        choices.addItem(.separator())
        _ = add("New Profile…", .newProfile, to: choices)
        setProfile.submenu = choices; setProfile.isEnabled = allowsProfileChange
        menu.addItem(setProfile)
        menu.addItem(.separator())
        _ = add("New Folder", .newFolder, to: menu)
        let live = NSMenuItem(title: "Live Folders", action: nil, keyEquivalent: "")
        let providers = NSMenu(title: "Live Folders")
        providers.autoenablesItems = false
        add("GitHub", .github, to: providers).state = hasGitHubFolder ? .on : .off
        live.submenu = providers
        menu.addItem(live)
        menu.addItem(.separator())
        if let source = exportSource {
            let export = NSMenuItem(title: "Export “\(source.name)” into Folder", action: nil, keyEquivalent: "")
            let destinations = NSMenu(); destinations.autoenablesItems = false
            for space in exportDestinations {
                let item = add(space.name, .exportInto(space.id), to: destinations)
                item.isEnabled = space !== source
            }
            export.submenu = destinations
            export.isEnabled = exportDestinations.contains { $0 !== source }
            menu.addItem(export)
            menu.addItem(.separator())
        }
        _ = add("Manage Spaces…", .manage, to: menu)
        menu.addItem(.separator())
        add("Delete Space", .delete, to: menu).isEnabled = canDelete
        return menu
    }

    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run(_ sender: Any?) { action() }
    }
}
