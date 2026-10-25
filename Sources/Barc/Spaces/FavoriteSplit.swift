// Modified for Barc: a Favorite destination can retain a complete split, 2026-10-25.
import Foundation

struct FavoriteSplit: Codable, Equatable, Sendable {
    struct Member: Codable, Equatable, Sendable {
        let id: UUID
        let page: SessionSnapshot.Tab
    }
    let id: UUID
    let members: [Member]
    var layout: SplitLayout
    var focusedMemberID: UUID?
    var stickyMemberID: UUID?
    var customName: String? = nil

    var isValid: Bool {
        (2...SplitLayout.maximumPanes).contains(members.count) && layout.isValid
            && Set(members.map(\.id)).count == members.count
            && Set(layout.tabIDs) == Set(members.map(\.id))
    }

    var record: SessionSnapshot.Split {
        let positions = Dictionary(members.enumerated().map { ($0.element.id,$0.offset) },uniquingKeysWith:{ first,_ in first })
        return .init(layout:layout,tabIndices:layout.tabIDs.compactMap { positions[$0] },
            stickyTabIndex:stickyMemberID.flatMap { positions[$0] },id:id,
            focusedTabIndex:focusedMemberID.flatMap { positions[$0] },customName:customName)
    }
}
