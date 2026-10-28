import AppKit
import Testing
@testable import Barc

@Suite("Activity grid retention")
@MainActor
struct ActivityGridRetentionTests {
    @Test func reusesCellsAcrossRefreshes() throws {
        let view = ActivityStatGridView(frame: .zero)
        view.show((0..<12).map { ("Name \($0)", "Value") })
        let grid = try #require(view.subviews.first as? NSGridView)
        let label = try #require(grid.row(at: 0).cell(at: 0).contentView)
        let subviewCount = grid.subviews.count
        for index in 0..<1_000 {
            view.show((0..<(index % 13)).map { ("Name \($0)", "\(index)") })
        }
        #expect(grid.numberOfRows == 6)
        #expect(grid.subviews.count == subviewCount)
        #expect(grid.row(at: 0).cell(at: 0).contentView === label)
    }
}
