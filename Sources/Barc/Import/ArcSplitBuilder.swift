// Modified for Barc: map current Arc split nodes into complete sidebar units, 2026-10-25.
import Foundation

enum ArcSplitBuilder {
    struct Built {
        let record: SessionSnapshot.Split
        let focusedIndex: Int
    }

    /// Focus remains useful even when unsupported geometry is left ungrouped.
    static func focusedIndex(root:String,items:[String:ArcSidebar.Item],children:(String)->[String],
                             tabIndices:[String:Int]) -> Int? {
        func find(_ id:String,target:String,path:Set<String>) -> Int? {
            guard path.count <= SplitLayout.maximumPanes,!path.contains(id) else { return nil }
            if id == target { return focus(id,path:path) }
            for child in children(id) {
                if let index = find(child,target:target,path:path.union([id])) { return index }
            }
            return nil
        }
        func focus(_ id:String,path:Set<String>) -> Int? {
            guard path.count <= SplitLayout.maximumPanes,!path.contains(id) else { return nil }
            if let index = tabIndices[id] { return index }
            let ids = children(id),next = path.union([id])
            if let preferred = items[id]?.split?.focusedItemID {
                for child in ids {
                    if let index = find(child,target:preferred,path:next) { return index }
                }
            }
            for child in ids { if let index = focus(child,path:next) { return index } }
            return nil
        }
        return focus(root,path:[])
    }

    static func build(root:String,items:[String:ArcSidebar.Item],children:(String)->[String],
                      tabIndices:[String:Int],prefix:String) -> Built? {
        var indices:[UUID:Int] = [:],visiting:Set<String> = []
        func node(_ id:String,share:Double) -> SplitLayout.Node? {
            guard visiting.count <= SplitLayout.maximumPanes,visiting.insert(id).inserted,let item = items[id] else { return nil }
            defer { visiting.remove(id) }
            if item.split == nil,item.url != nil,let index = tabIndices[id] {
                let slot = ArcImportID.uuid(prefix+"/split-leaf/"+id)
                indices[slot] = index
                return .pane(id:slot,share:share)
            }
            guard item.url == nil,!item.isFolder,let split = item.split,let axis = split.axis,let weights = split.weights else { return nil }
            let ids = children(id)
            guard (2...SplitLayout.maximumPanes).contains(ids.count),Set(ids).count == ids.count,
                  weights.isEmpty || Set(weights.keys) == Set(ids) else { return nil }
            let raw = ids.map { weights[$0] ?? 1 }
            guard raw.allSatisfy({ $0.isFinite && $0 > 0 }),let scale = raw.max() else { return nil }
            let values = raw.map { $0/scale },sum = values.reduce(0,+)
            guard sum.isFinite,sum > 0 else { return nil }
            var nodes:[SplitLayout.Node] = []
            for (id,value) in zip(ids,values) {
                guard let next = node(id,share:value/sum) else { return nil }
                nodes.append(next)
            }
            return .split(axis:axis,children:nodes,share:share)
        }
        guard let rootNode = node(root,share:1),let split = items[root]?.split,let axis = split.axis else { return nil }
        var grid:SplitLayout.Grid = axis == .horizontal ? .sideBySide:.stacked
        if case .split(.horizontal,let columns,_) = rootNode,columns.count == 2 {
            let stacked = columns.filter { if case .split(.vertical,_,_) = $0 { true } else { false } }
            let isColumn = columns.allSatisfy { column in
                switch column {
                case .pane: true
                case .split(.vertical,let panes,_): panes.count == 2 && panes.allSatisfy { if case .pane = $0 { true } else { false } }
                default: false
                }
            }
            if !stacked.isEmpty,isColumn { grid = .grid }
        }
        guard let layout = SplitLayout(validating:rootNode,grid:grid),layout.tabIDs.count >= 2,
              Set(layout.tabIDs).count == layout.tabIDs.count,
              layout.tabIDs.allSatisfy({ indices[$0] != nil }) else { return nil }
        let focused = focusedIndex(root:root,items:items,children:children,tabIndices:tabIndices) ?? indices[layout.tabIDs[0]]!
        return Built(record:.init(layout:layout,tabIndices:layout.tabIDs.map { indices[$0]! },
            stickyTabIndex:nil,id:ArcImportID.uuid(prefix+"/split/"+root),focusedTabIndex:focused,customName:SplitCollection.normalizedName(items[root]?.customName)),focusedIndex:focused)
    }
}
