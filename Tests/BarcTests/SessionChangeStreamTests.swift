// Modified for Barc: synchronous and nested model-change delivery, 2026-10-25.
import Combine
import Testing
@testable import Barc

@Suite("Session change batches", .serialized)
@MainActor
struct SessionChangeStreamTests {
    private func name(_ event:BrowserSession.Change) -> String {
        switch event {
        case .spaces: "spaces"
        case .structure: "structure"
        case .tabs: "tabs"
        case .activeTab: "active"
        case .bookmarks: "bookmarks"
        case .tab: "page"
        }
    }

    @Test("Ordinary events stay immediate and nested edits reveal only the completed model without losing page or bookmark updates")
    func nested() {
        let stream = SessionChangeStream(), page = TestSession.make().0.activeTab!
        var revision = 0, seen:[String] = []
        let token = stream.sink { seen.append("\(name($0))-\(revision)") }
        defer { token.cancel() }
        stream.send(.tabs)
        #expect(seen == ["tabs-0"])
        let value = stream.batch {
            revision = 1;stream.send(.tabs)
            stream.batch {
                revision = 2;stream.send(.structure);stream.send(.spaces)
                stream.send(.bookmarks);stream.send(.activeTab)
                stream.send(.tab(page));stream.send(.tab(page))
            }
            #expect(seen == ["tabs-0"])
            revision = 3
            return 17
        }
        #expect(value == 17)
        #expect(seen == ["tabs-0","spaces-3","bookmarks-3","active-3","page-3"])
        stream.send(.tabs)
        #expect(seen.last == "tabs-3")
    }

    @Test("A failing operation releases its committed updates and subscriber edits cannot lose later notifications")
    func throwingAndReentrant() {
        enum Failure:Error { case expected }
        let stream = SessionChangeStream()
        var seen:[String] = []
        let token = stream.sink { event in
            seen.append(name(event))
            if case .structure = event { stream.batch { stream.send(.bookmarks) } }
        }
        defer { token.cancel() }
        #expect(throws:Failure.self) {
            try stream.batch {
                stream.send(.tabs);stream.send(.structure);stream.send(.activeTab)
                throw Failure.expected
            }
        }
        stream.send(.tabs)
        #expect(seen == ["structure","bookmarks","active","tabs"])
    }
}
