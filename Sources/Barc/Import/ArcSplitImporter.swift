// Modified for Barc: enrich old flat imports once without undoing local edits, 2026-10-25.
import Foundation

@MainActor
extension BrowserSession {
    /// Upgrade the old single-tile representation only while its source pages
    /// remain in their original positions. A skipped unit is remembered too.
    func prepareArcFavoriteSplits(_ stored:SessionSnapshot.Space,into space:Space) -> (tabs:Int,favorites:Int) {
        var addedTabs = 0,addedFavorites = 0
        for pin in stored.pinnedSites ?? [] {
            guard let split = pin.split,split.isValid,
                  !space.importedSplitIDs.contains(split.id),
                  !space.pinnedSites.contains(where:{ $0.id == pin.id }) else { continue }
            let originals = split.members.compactMap { member in
                stored.tabs.first { $0.pinnedSiteID == pin.id && $0.pinnedMemberID == member.id }
            }
            guard originals.count == split.members.count else { continue }
            func matchesSource(_ current:String?,_ original:String) -> Bool {
                guard let current,let boundary = original.range(of:"/tab/"),
                      let leaf = original.split(separator:"/").last else { return false }
                return current.hasPrefix(original[..<boundary.upperBound]) && current.hasSuffix("/"+leaf)
            }
            let archived = archivedTabs.filter { record in
                spaces.first(where:{ $0.id == record.spaceID })?.identity == space.identity
            }.flatMap(\.snapshots).compactMap(\.importedSourceID)
            var found:[Tab?] = [],claimed:Set<UUID> = [],oldPins:Set<UUID> = [],valid = true
            for original in originals {
                guard let source = original.importedSourceID else { valid = false;break }
                let oldID = ArcImportID.uuid(source.replacingOccurrences(of:"/tab/",with:"/pin/"))
                let alias = space.profile.tab(forPinnedAlias:oldID) ?? space.profile.favoriteTabs.first { page in
                    guard let oldSource = page.importedSourceID,let boundary = source.range(of:"/tab/") else { return false }
                    return page.pinnedMemberID == nil && page.url == original.url
                        && oldSource.hasPrefix(source[..<boundary.upperBound])
                        && page.pinnedSiteID == ArcImportID.uuid(oldSource.replacingOccurrences(of:"/tab/",with:"/pin/"))
                }
                let peers = spaces.filter { $0.profile === space.profile }.flatMap(\.tabs).filter {
                    matchesSource($0.importedSourceID,source)
                }
                if peers.contains(where:{ $0.groupID != original.groupID || $0.keepsInSidebar != (original.keepsInSidebar == true)
                    || $0.url != original.url || $0.customName != original.customName || $0.sidebarIcon.isCustomized || $0.isLocked
                    || $0.sidebarPosition != original.sidebarPosition || isInLiveFolder($0) }) { valid = false;break }
                let current = space.tabs.first { $0.importedSourceID == source }
                    ?? space.profile.favoriteTabs.first { matchesSource($0.importedSourceID,source) }
                    ?? alias
                if archived.contains(where:{ matchesSource($0,source) }) { valid = false;break }
                guard let current else {
                    if space.profile.importedFavoriteIDs.contains(where:{ matchesSource($0,source) }) { valid = false;break }
                    found.append(nil);continue
                }
                let isAliasCopy = current === alias && !matchesSource(current.importedSourceID,source)
                guard current.groupID == original.groupID,current.keepsInSidebar == (original.keepsInSidebar == true),
                      current.url == original.url,current.customName == original.customName,!current.isLocked,
                      !isInLiveFolder(current),space.splits.layout(containing:current.id) == nil,
                      isAliasCopy || current.sidebarPosition == original.sidebarPosition,
                      alias != nil,current.pinnedSiteID == nil || current.pinnedSiteID == alias?.pinnedSiteID else { valid = false;break }
                if let old = alias?.pinnedSiteID {
                    guard space.pinnedSites.first(where:{ $0.id == old })?.icon.isCustomized != true else { valid = false;break }
                    oldPins.insert(old)
                }
                // An older URL alias may have coalesced identical source panes.
                // Keep its live page once and recreate the other destination.
                found.append(claimed.insert(current.id).inserted ? current:nil)
            }
            guard valid else { space.importedSplitIDs.insert(split.id);continue }
            space.addPinnedSite(.init(id:pin.id,url:pin.url,title:pin.title,split:split,icon:pin.icon ?? .automatic));addedFavorites += 1
            for (offset,original) in originals.enumerated() {
                let page:Tab
                if let existing = found[offset] {
                    page = existing
                    space.profile.removeFavorite(page)
                    page.setPinnedSiteID(pin.id);page.setPinnedMemberID(original.pinnedMemberID)
                    space.promoteFavorite(page)
                } else {
                    page = restoreImportedTab(original,into:space);addedTabs += 1
                }
                if let source = original.importedSourceID {
                    for owner in spaces where owner.profile === space.profile {
                        for copy in owner.workspaceTabs where copy !== page && matchesSource(copy.importedSourceID,source)
                            && owner.splits.layout(containing:copy.id) == nil && BrowserProfile.sameFavoriteCopy(page,copy) {
                            let wasActive = owner.activeTab === copy
                            copy.setPinnedSiteID(pin.id);copy.setPinnedMemberID(original.pinnedMemberID)
                            owner.promoteFavorite(copy)
                            if wasActive { owner.setActiveTabID(page.id) }
                        }
                    }
                }
            }
            for old in space.pinnedSites where oldPins.contains(old.id)
                && !space.profile.favoriteTabs.contains(where:{ $0.pinnedSiteID == old.id }) {
                space.profile.removePinnedSite(old)
            }
        }
        return (addedTabs,addedFavorites)
    }

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
                let favorite = original.pinnedSiteID.flatMap { pin in
                    stored.pinnedSites?.first { $0.id == pin && $0.split?.id == record.id }
                }
                let tab:Tab?
                if let favorite {
                    tab = space.profile.favoriteTabs.first { $0.pinnedSiteID == favorite.id && $0.pinnedMemberID == original.pinnedMemberID }
                } else {
                    tab = space.workspaceTabs.first { $0.importedSourceID == original.importedSourceID
                        && original.pinnedSiteID == nil && $0.pinnedSiteID == nil && $0.groupID == original.groupID
                        && $0.keepsInSidebar == (original.keepsInSidebar == true) && $0.sidebarPosition == original.sidebarPosition }
                }
                guard original.importedSourceID != nil,let tab,space.splits.layout(containing:tab.id) == nil else { break }
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
