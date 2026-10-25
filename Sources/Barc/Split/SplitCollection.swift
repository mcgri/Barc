// Modified for Barc: independent split groups and restoration without persistent tab IDs, 2026-10-24.
import Foundation

/// The independent splits in one Space. A tab belongs to at most one group.
struct SplitCollection: Equatable, Sendable {
    private(set) var layouts: [SplitLayout] = []
    private(set) var stickyTabIDs: Set<UUID> = []
    private var identifiers: [UUID] = []
    private var focusedTabs: [UUID: UUID] = [:]
    private var icons: [UUID: SpaceIcon] = [:]
    private var names: [UUID: String] = [:]

    static func normalizedName(_ value:String?) -> String? {
        guard let value = value?.trimmingCharacters(in:.whitespacesAndNewlines),!value.isEmpty else { return nil }
        return value
    }

    func name(containing tabID:UUID) -> String? {
        identifier(containing:tabID).flatMap { names[$0] }
    }

    @discardableResult
    mutating func setName(_ value:String?,containing tabID:UUID) -> Bool {
        guard let id = identifier(containing:tabID) else { return false }
        let name = Self.normalizedName(value)
        guard names[id] != name else { return false }
        names[id] = name
        return true
    }

    func icon(containing tabID:UUID) -> SpaceIcon {
        identifier(containing:tabID).flatMap { icons[$0] } ?? .automatic
    }

    @discardableResult
    mutating func setIcon(_ icon:SpaceIcon,containing tabID:UUID) -> Bool {
        guard let id = identifier(containing:tabID),icon != (icons[id] ?? .automatic) else { return false }
        icons[id] = icon.isCustomized ? icon:nil
        return true
    }

    func identifier(containing tabID: UUID) -> UUID? {
        layouts.firstIndex(where: { $0.contains(tabID) }).map { identifiers[$0] }
    }

    func preferredTab(containing tabID: UUID) -> UUID? {
        guard let index = layouts.firstIndex(where: { $0.contains(tabID) }) else { return nil }
        return focusedTabs[identifiers[index]] ?? layouts[index].tabIDs.first
    }

    mutating func focus(_ tabID: UUID) {
        guard let id = identifier(containing: tabID) else { return }
        focusedTabs[id] = tabID
    }

    func layout(containing id: UUID?) -> SplitLayout? {
        guard let id else { return nil }
        return layouts.first { $0.contains(id) }
    }

    /// Extending a group preserves its proportions. Joining two groups carries
    /// every member over, and refuses the whole operation if four panes won't fit.
    @discardableResult
    mutating func join(_ ids: [UUID], grid: SplitLayout.Grid) -> Bool {
        let unique = ids.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        guard unique.count >= 2 else { return false }
        let touched = layouts.indices.filter { index in unique.contains(where: layouts[index].contains) }
        var expanded: [UUID] = []
        for id in unique {
            for member in layout(containing: id)?.tabIDs ?? [id] where !expanded.contains(member) {
                expanded.append(member)
            }
        }
        guard expanded.count <= SplitLayout.maximumPanes else { return false }
        var result: SplitLayout
        if let original = layout(containing: unique.first) {
            result = original
            for id in expanded where !result.contains(id) {
                guard let next = result.adding(id) else { return false }
                result = next
            }
        } else {
            guard let created = SplitLayout(tabs: expanded, grid: grid) else { return false }
            result = created
        }
        let insertion = touched.first ?? layouts.count
        let identifier = identifier(containing: unique[0]) ?? touched.first.map { identifiers[$0] } ?? UUID()
        let focus = focusedTabs[identifier] ?? unique[0]
        let icon = icons[identifier]
        let name = names[identifier]
        for index in touched.reversed() {
            focusedTabs[identifiers[index]] = nil
            icons[identifiers[index]] = nil
            names[identifiers[index]] = nil
            identifiers.remove(at: index)
            layouts.remove(at: index)
        }
        layouts.insert(result, at: insertion)
        identifiers.insert(identifier, at: insertion)
        focusedTabs[identifier] = focus
        icons[identifier] = icon
        names[identifier] = name
        // A combined split has one sticky pane; keep the first group's choice.
        let sticky = result.tabIDs.first(where: stickyTabIDs.contains)
        stickyTabIDs.subtract(result.tabIDs)
        if let sticky { stickyTabIDs.insert(sticky) }
        return true
    }

    /// A sidebar drop targets one pane, retaining the destination group's
    /// identity and the internal geometry of any complete incoming units.
    @discardableResult
    mutating func insert(_ ids: [UUID], beside target: UUID, on side: SplitLayout.InsertionSide) -> Bool {
        let original = layout(containing:target)
        let targetIDs = Set(original?.tabIDs ?? [target])
        var roots: [SplitLayout.Node] = []
        var incoming: Set<UUID> = []
        for id in ids where !incoming.contains(id) {
            if let unit = layout(containing:id) {
                guard targetIDs.isDisjoint(with:unit.tabIDs) else { return false }
                roots.append(unit.root)
                incoming.formUnion(unit.tabIDs)
            } else {
                guard !targetIDs.contains(id) else { return false }
                roots.append(.pane(id:id,share:1))
                incoming.insert(id)
            }
        }
        guard let result = SplitLayout(inserting:roots,beside:target,on:side,into:original) else { return false }
        let touched = layouts.indices.filter { index in
            layouts[index].contains(target) || !incoming.isDisjoint(with:layouts[index].tabIDs)
        }
        let insertion = touched.first ?? layouts.count
        let identifier = identifier(containing:target) ?? UUID()
        let focus = focusedTabs[identifier] ?? target
        let icon = icons[identifier]
        let name = names[identifier]
        let sticky = original?.tabIDs.first(where:stickyTabIDs.contains) ?? result.tabIDs.first(where:stickyTabIDs.contains)
        for index in touched.reversed() {
            focusedTabs[identifiers[index]] = nil
            icons[identifiers[index]] = nil
            names[identifiers[index]] = nil
            identifiers.remove(at:index); layouts.remove(at:index)
        }
        layouts.insert(result,at:insertion); identifiers.insert(identifier,at:insertion)
        focusedTabs[identifier] = focus
        icons[identifier] = icon
        names[identifier] = name
        stickyTabIDs.subtract(result.tabIDs)
        if let sticky { stickyTabIDs.insert(sticky) }
        return true
    }

    @discardableResult
    mutating func update(_ layout: SplitLayout) -> Bool {
        guard layout.isValid,
              let index = layouts.firstIndex(where: { $0.tabIDs == layout.tabIDs }) else { return false }
        layouts[index] = layout
        return true
    }

    mutating func replace(_ oldID: UUID, with newID: UUID) {
        guard layout(containing: newID) == nil,
              let index = layouts.firstIndex(where: { $0.contains(oldID) }) else { return }
        layouts[index] = layouts[index].replacing(oldID, with: newID)
        if focusedTabs[identifiers[index]] == oldID { focusedTabs[identifiers[index]] = newID }
        if stickyTabIDs.remove(oldID) != nil { stickyTabIDs.insert(newID) }
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> SplitLayout.Removal? {
        guard let index = layouts.firstIndex(where: { $0.contains(id) }),
              let removal = layouts[index].removing(id) else { return nil }
        stickyTabIDs.remove(id)
        switch removal {
        case .dissolved:
            stickyTabIDs.subtract(layouts[index].tabIDs)
            focusedTabs[identifiers[index]] = nil
            icons[identifiers[index]] = nil
            names[identifiers[index]] = nil
            identifiers.remove(at: index)
            layouts.remove(at: index)
        case .resized(let layout):
            layouts[index] = layout
            if focusedTabs[identifiers[index]] == id { focusedTabs[identifiers[index]] = layout.tabIDs.first }
        }
        return removal
    }

    mutating func dissolve(containing id: UUID) {
        guard let index = layouts.firstIndex(where: { $0.contains(id) }) else { return }
        stickyTabIDs.subtract(layouts[index].tabIDs)
        focusedTabs[identifiers[index]] = nil
        icons[identifiers[index]] = nil
        names[identifiers[index]] = nil
        identifiers.remove(at: index)
        layouts.remove(at: index)
    }

    mutating func toggleSticky(_ id: UUID) {
        guard let layout = layout(containing: id) else { return }
        let wasSticky = stickyTabIDs.contains(id)
        stickyTabIDs.subtract(layout.tabIDs)
        if !wasSticky { stickyTabIDs.insert(id) }
    }

    func retaining(_ ids: Set<UUID>) -> Self {
        var copy = self
        for id in layouts.flatMap(\.tabIDs) where !ids.contains(id) { copy.remove(id) }
        return copy
    }

    /// Copies complete groups through an explicit old-page to new-page binding.
    /// Partial groups and overlapping destinations are left alone. Matching
    /// URLs are never used as identity, since several panes may show one URL.
    /// Existing group identities force fresh identities for copies. The return
    /// value contains source group IDs, so a move can remove those originals.
    @discardableResult
    mutating func copyCompleteGroups(from source: Self, mapping: [UUID: UUID]) -> Set<UUID> {
        var transferred: Set<UUID> = []
        for original in source.layouts {
            guard let first = original.tabIDs.first,
                  let originalID = source.identifier(containing:first),
                  let layout = original.mappingTabs({ mapping[$0] }),
                  layout.tabIDs.allSatisfy({ self.layout(containing:$0) == nil }) else { continue }
            let id = identifiers.contains(originalID) ? UUID() : originalID
            layouts.append(layout)
            identifiers.append(id)
            icons[id] = source.icons[originalID]
            names[id] = source.names[originalID]
            if let focus = source.preferredTab(containing:first).flatMap({ mapping[$0] }) {
                focusedTabs[id] = focus
            }
            for sticky in original.tabIDs where source.stickyTabIDs.contains(sticky) {
                if let mapped = mapping[sticky] { stickyTabIDs.insert(mapped) }
            }
            transferred.insert(originalID)
        }
        return transferred
    }

    /// Slots refer to the enclosing saved tab array, so duplicate URLs remain
    /// distinct and restoring a group never needs to guess a tab's identity.
    func snapshot(tabIDs: [UUID]) -> [SessionSnapshot.Split]? {
        let positions = Dictionary(tabIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let saved = layouts.enumerated().compactMap { index, layout -> SessionSnapshot.Split? in
            let indices = layout.tabIDs.compactMap { positions[$0] }
            guard indices.count == layout.paneCount else { return nil }
            return SessionSnapshot.Split(layout: layout, tabIndices: indices,
                stickyTabIndex: layout.tabIDs.first(where: stickyTabIDs.contains).flatMap { positions[$0] },
                id: identifiers[index], focusedTabIndex: focusedTabs[identifiers[index]].flatMap { positions[$0] },icon:icons[identifiers[index]],customName:names[identifiers[index]])
        }
        return saved.isEmpty ? nil : saved
    }

    static func restoring(_ records: [SessionSnapshot.Split]?, tabIDs: [UUID]) -> Self {
        var result = Self()
        for record in records ?? [] {
            let oldIDs = record.layout.tabIDs
            guard oldIDs.count == record.tabIndices.count,
                  record.tabIndices.allSatisfy(tabIDs.indices.contains),
                  Set(record.tabIndices).count == record.tabIndices.count else { continue }
            let bindings = Dictionary(zip(oldIDs, record.tabIndices.map { tabIDs[$0] }), uniquingKeysWith: { first, _ in first })
            guard let layout = record.layout.mappingTabs({ bindings[$0] }),
                  layout.tabIDs.allSatisfy({ result.layout(containing: $0) == nil }) else { continue }
            result.layouts.append(layout)
            let id = record.id.flatMap { result.identifiers.contains($0) ? nil : $0 } ?? UUID()
            result.identifiers.append(id)
            if let icon = record.icon,icon.isCustomized { result.icons[id] = icon }
            result.names[id] = normalizedName(record.customName)
            if let index = record.focusedTabIndex, record.tabIndices.contains(index), tabIDs.indices.contains(index) {
                result.focusedTabs[id] = tabIDs[index]
            }
            if let index = record.stickyTabIndex, record.tabIndices.contains(index), tabIDs.indices.contains(index) {
                result.stickyTabIDs.insert(tabIDs[index])
            }
        }
        return result
    }
}
