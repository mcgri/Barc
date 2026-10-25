// Modified for Barc: enrich old flat imports once without undoing local edits, 2026-10-25.
import Foundation

@MainActor
extension BrowserSession {
    func mergeArcSplits(_ stored:SessionSnapshot.Space,into space:Space) {
        guard spaces.contains(where:{ $0 === space }),!space.isPrivate else { return }
        for record in stored.splits ?? [] {
            guard let id = record.id,!space.importedSplitIDs.contains(id),record.layout.isValid,
                  record.tabIndices.count == record.layout.tabIDs.count,
                  Set(record.tabIndices).count == record.tabIndices.count,
                  record.tabIndices.allSatisfy(stored.tabs.indices.contains) else { continue }
            // A later reimport must not regroup a unit the user separated, moved,
            // archived or reorganized after this source unit was first considered.
            space.importedSplitIDs.insert(id)
            var slots = stored.tabs.map { _ in UUID() },members:[Tab] = []
            for index in record.tabIndices {
                let original = stored.tabs[index]
                guard let source = original.importedSourceID,
                      let tab = space.workspaceTabs.first(where:{ $0.importedSourceID == source }),
                      original.pinnedSiteID == nil,tab.pinnedSiteID == nil,
                      tab.groupID == original.groupID,tab.keepsInSidebar == (original.keepsInSidebar == true),
                      tab.sidebarPosition == original.sidebarPosition,
                      space.splits.layout(containing:tab.id) == nil else { break }
                slots[index] = tab.id;members.append(tab)
            }
            guard members.count == record.tabIndices.count else { continue }
            let incoming = SplitCollection.restoring([record],tabIDs:slots)
            space.splits.copyCompleteGroups(from:incoming,
                mapping:Dictionary(uniqueKeysWithValues:members.map { ($0.id,$0.id) }))
            if let active = space.activeTab,members.contains(where:{ $0 === active }) {
                space.splits.focus(active.id)
            }
        }
    }
}
