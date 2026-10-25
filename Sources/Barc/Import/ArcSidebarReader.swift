// Modified for Barc: import Space icons, sidebar width and split metadata, 2026-10-25.
import Foundation
import CoreFoundation

/// Reads the current local sidebar, not the stale cloud-sync replicas beside it.
enum ArcSidebarReader {
    static func dictionary(_ raw: Any?) throws -> [(String, [String: Any])] {
        if let map = raw as? [String: [String: Any]] {
            return map.keys.sorted().compactMap { key in map[key].map { (key, $0) } }
        }
        guard let array = raw as? [Any] else { return [] }
        if array.allSatisfy({ $0 is [String: Any] }) {
            return array.compactMap { value in
                guard let object = value as? [String: Any], let id = object["id"] as? String else { return nil }
                return (id, object)
            }
        }
        guard array.count.isMultiple(of: 2) else { throw ArcImportFailure.invalidSidebar }
        return try stride(from: 0, to: array.count, by: 2).map { index in
            guard let id = array[index] as? String, let object = array[index + 1] as? [String: Any] else {
                throw ArcImportFailure.invalidSidebar
            }
            return (id, object)
        }
    }

    static func profileFolder(_ value: Any?) -> String? {
        guard let profile = value as? [String: Any] else { return nil }
        if profile["default"] != nil { return "Default" }
        let custom = profile["custom"] as? [String: Any]
        return (custom?["_0"] as? [String: Any])?["directoryBasename"] as? String
            ?? custom?["directoryBasename"] as? String
    }

    static func read(sidebar data: Data, archive: Data?, profiles: [ArcProfile], windows: Data? = nil) throws -> ArcSidebar {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any] else { throw ArcImportFailure.invalidSidebar }
        var itemObjects: [(String, [String: Any])] = []
        var spaceObjects: [(String, [String: Any])] = []
        var favorites: [String: String] = [:]
        for value in containers {
            guard let container = value as? [String: Any] else { continue }
            itemObjects += try dictionary(container["items"])
            spaceObjects += try dictionary(container["spaces"])
            if let roots = container["topAppsContainerIDs"] as? [Any], roots.count.isMultiple(of: 2) {
                for index in stride(from: 0, to: roots.count, by: 2) {
                    if let profile = profileFolder(roots[index]), let id = roots[index + 1] as? String {
                        favorites[profile] = id
                    }
                }
            }
        }
        guard !spaceObjects.isEmpty else { throw ArcImportFailure.invalidSidebar }
        let windowState = windows.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let savedWindows = windowState?["windows"] as? [[String: Any]] ?? []
        let frontWindow = savedWindows.first { ($0["focusedSpaceID"] as? String) == (windowState?["lastFocusedSpaceID"] as? String) }
            ?? savedWindows.first
        let expandedFolders = (frontWindow?["expandedItems"] as? [String]).map(Set.init)
        let foldedSpaces = (frontWindow?["spacesWithCollapsedPinnedSections"] as? [String]).map(Set.init)
        var items: [String: ArcSidebar.Item] = [:]
        var orderedIDs: [String] = []
        var skipped = 0
        for (key, object) in itemObjects {
            guard items[key] == nil else { continue }
            let payload = object["data"] as? [String: Any] ?? [:]
            let tab = payload["tab"] as? [String: Any]
            let url = (tab?["savedURL"] as? String).flatMap(validURL)
            let folder = payload["list"] as? [String: Any]
            let folderInfo = folder?["customInfo"] as? [String: Any]
            let folderIcon = folderInfo?["iconType"] as? [String: Any]
            let folderEmoji = folderIcon?["emoji_v2"] as? String
                ?? (folderIcon?["emoji"] as? Int).flatMap(UnicodeScalar.init).map(String.init)
            if tab != nil, url == nil { skipped += 1 }
            items[key] = ArcSidebar.Item(
                id: key, parentID: object["parentID"] as? String, title: object["title"] as? String ?? tab?["savedTitle"] as? String,
                children: object["childrenIds"] as? [String] ?? [], url: url,
                isFolder: payload["list"] != nil,
                lastActiveAt: (tab?["timeLastActiveAt"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) },
                customName: object["title"] as? String,
                isCollapsed: payload["list"] != nil ? expandedFolders.map { !$0.contains(key) } : nil,
                folderEmoji: folderEmoji, folderBadge: folderIcon?["icon"] as? String,
                split: (payload["splitView"] as? [String:Any]).map(readSplit)
            )
            orderedIDs.append(key)
        }
        var spaces: [ArcSidebar.Space] = []
        let knownProfiles = Set(profiles.map(\.folder))
        let sync = root["firebaseSyncState"] as? [String: Any]
        let syncData = sync?["syncData"] as? [String: Any]
        let order = (syncData?["orderedSpaceIDs"] as? [String: Any])?["value"] as? [String] ?? []
        for (index, entry) in spaceObjects.enumerated() {
            let (key, object) = entry
            guard !spaces.contains(where: { $0.id == key }), let folder = profileFolder(object["profile"]),
                  knownProfiles.contains(folder) else { throw ArcImportFailure.invalidSidebar }
            let info = object["customInfo"] as? [String: Any] ?? [:]
            let title = [info["name"],info["title"],object["title"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            let name = title ?? "Space \((order.firstIndex(of:key) ?? index) + 1)"
            var roots: [String: String] = [:]
            if let pairs = object["containerIDs"] as? [String], pairs.count.isMultiple(of: 2) {
                for index in stride(from: 0, to: pairs.count, by: 2) { roots[pairs[index]] = pairs[index + 1] }
            }
            if let pairs = object["newContainerIDs"] as? [Any], pairs.count.isMultiple(of: 2) {
                for index in stride(from: 0, to: pairs.count, by: 2) {
                    guard let tag = pairs[index] as? [String: Any], let id = pairs[index + 1] as? String else { continue }
                    if tag["pinned"] != nil { roots["pinned"] = id }
                    if tag["unpinned"] != nil { roots["unpinned"] = id }
                }
            }
            let theme = info["windowTheme"] as? [String: Any]
            let palette = theme?["primaryColorPalette"] as? [String: Any]
            let color = palette?["midTone"] as? [String: Any]
            let hex: String? = color.flatMap {
                guard let r = $0["red"] as? Double, let g = $0["green"] as? Double, let b = $0["blue"] as? Double,
                      [r, g, b].allSatisfy(\.isFinite) else { return nil }
                // Arc stores extended-sRGB components, including tiny float
                // overshoots and colours outside ordinary sRGB. Barc's hex
                // model uses the closest in-range component for each channel.
                let channels = [r, g, b].map { Int((min(1, max(0, $0)) * 255).rounded()) }
                return String(format: "#%02x%02x%02x", channels[0], channels[1], channels[2])
            }
            let icon = info["iconType"] as? [String: Any]
            let emoji = icon?["emoji_v2"] as? String ?? (icon?["emoji"] as? Int).flatMap(UnicodeScalar.init).map(String.init)
            let symbol = (icon?["icon"] as? String).flatMap(SpaceSymbols.storedName(forArcName:))
            spaces.append(.init(id: key, name: name, profile: folder, pinnedRoot: roots["pinned"], unpinnedRoot: roots["unpinned"], color: hex, emoji: emoji,
                                symbolName: symbol, chrome: ImportedChrome.read(theme), pinnedSectionCollapsed: foldedSpaces.map { $0.contains(key) }))
        }
        if Set(order).isSuperset(of: Set(spaces.map(\.id))) {
            spaces.sort { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
        }
        var archived: [ArcSidebar.Archived] = []
        if let archive {
            guard let object = try? JSONSerialization.jsonObject(with: archive) as? [String: Any] else {
                throw ArcImportFailure.unreadable("tab archive")
            }
            for (key, record) in try dictionary(object["items"]) {
                let item = record["sidebarItem"] as? [String: Any] ?? [:]
                let payload = item["data"] as? [String: Any]
                let tab = payload?["tab"] as? [String: Any]
                guard let raw = tab?["savedURL"] as? String, let url = validURL(raw) else { skipped += 1; continue }
                let source = record["source"] as? [String: Any]
                let space = source?["space"] as? [String: Any]
                archived.append(.init(id: key, spaceID: space?["_0"] as? String ?? source?["space"] as? String,
                                      url: url, title: item["title"] as? String ?? tab?["savedTitle"] as? String,
                                      date: Date(timeIntervalSinceReferenceDate: record["archivedAt"] as? Double ?? 0), customName: item["title"] as? String))
            }
        }
        var output = ArcSidebar(spaces: spaces, items: items, orderedItemIDs: orderedIDs, favoritesRoots: favorites, archived: archived, skippedItems: skipped)
        if let number = frontWindow?["sidebarWidth"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue > 0 {
            output.sidebarWidth = number.doubleValue
        }
        if let windows, let root = try? JSONSerialization.jsonObject(with: windows) as? [String: Any] {
            output.activeSpaceID = root["lastFocusedSpaceID"] as? String
            for window in root["windows"] as? [[String: Any]] ?? [] {
                guard let space = window["focusedSpaceID"] as? String, let contents = window["contents"] as? [String: Any],
                      let focused = (contents["splitViewState"] as? [String: Any])?["focusedContentID"] as? String,
                      let map = (contents["windowContentSidebarItemMap"] as? [String: Any])?["keysToValues"] as? [String], map.count.isMultiple(of: 2) else { continue }
                for index in stride(from: 0, to: map.count, by: 2) where map[index] == focused && items[map[index + 1]] != nil {
                    output.selectedItems[space] = map[index + 1]
                }
            }
        }
        return output
    }

    static func validURL(_ string: String) -> URL? {
        guard let url = ArcURL.parse(string), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return nil }
        return url
    }

    private static func readSplit(_ data:[String:Any]) -> ArcSidebar.Split {
        let axis:SplitLayout.Axis? = switch data["layoutOrientation"] as? String {
        case "horizontal": .horizontal
        case "vertical": .vertical
        default: nil
        }
        func weight(_ value:Any) -> Double? {
            guard let number = value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,number.doubleValue > 0 else { return nil }
            return number.doubleValue
        }
        func weights(_ raw:Any?) -> [String:Double]? {
            guard let raw,!(raw is NSNull) else { return [:] }
            var result:[String:Double] = [:]
            if let map = raw as? [String:Any] {
                for (id,value) in map {
                    guard let value = weight(value) else { return nil }
                    result[id] = value
                }
                return result
            }
            // Swift dictionaries with wrapped IDs use alternating key/value
            // entries. Unknown shapes are retained as loose pages by the builder.
            guard let pairs = raw as? [Any],pairs.count.isMultiple(of:2) else { return nil }
            for index in stride(from:0,to:pairs.count,by:2) {
                guard let id = pairs[index] as? String,result[id] == nil,
                      let value = weight(pairs[index+1]) else { return nil }
                result[id] = value
            }
            return result
        }
        return .init(axis:axis,weights:weights(data["itemWidthFactors"]),focusedItemID:data["focusItemID"] as? String)
    }
}
