import AppKit
import Testing
@testable import Barc

@Suite("Activity refresh retention", .serialized)
@MainActor
struct ActivityRefreshRetentionTests {
    private func identities(_ view: NSView) -> [ObjectIdentifier] {
        [ObjectIdentifier(view)] + view.subviews.flatMap { identities($0) }
    }

    @Test func steadyRefreshReusesViews() {
        let session = BrowserSession(database: nil)
        let space = session.addSpace(named: "Work")
        let rail = ActivityRailView(frame: .zero)
        rail.build(spaces: session.spaces, accent: .systemBlue)
        let scope = ActivityScopeBar(frame: .zero)
        let bars = ActivityBarListView(frame: .zero)
        let composition = ActivityCompositionView(frame: .zero)
        let ids = [UUID(), UUID(), UUID(), UUID()]
        func refresh(_ iteration: Int) {
            let values = ids.enumerated().map { index, id in
                ActivityBar(id: id, label: "Item \(index): \(iteration)", value: Double(iteration),
                            caption: "\(iteration)", fraction: 0.25, isDimmed: iteration % 2 == 0)
            }
            bars.tint = iteration % 2 == 0 ? .systemBlue : .systemRed
            bars.show(values)
            composition.show(values)
            scope.show([.init(scope: .everything, title: "Browser \(iteration)", detail: "\(iteration)",
                              image: nil, symbol: "globe", tint: .systemBlue)], selected: .everything)
            rail.show(scope: .space(space.id))
            rail.show(memoryBySpace: [space.id: UInt64(iteration)])
        }
        refresh(0)
        let views: [NSView] = [bars, composition, scope, rail]
        let original = views.map { identities($0) }
        for iteration in 1...500 {
            refresh(iteration)
            #expect(views.map { identities($0) } == original)
        }
    }

    @Test func closingReleasesControllerAndReopeningCreatesFreshContent() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(database: nil)
        weak var previousController: TaskManagerWindowController?
        weak var previousContent: NSViewController?
        autoreleasepool {
            let controller = TaskManagerWindowController(session: session)
            TaskManagerWindowController.current = controller
            previousController = controller
            previousContent = controller.window?.contentViewController
            controller.window?.close()
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(previousController == nil)
        #expect(previousContent == nil)
        #expect(TaskManagerWindowController.current == nil)
        TaskManagerWindowController.show(session: session)
        let reopened = try #require(TaskManagerWindowController.current)
        #expect(reopened.window?.contentViewController is TaskManagerViewController)
        reopened.window?.close()
        #expect(TaskManagerWindowController.current == nil)
    }
}
