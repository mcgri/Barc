// Modified for Barc: complete sidebar operations publish one finished state, 2026-10-25.
import Combine
import Foundation

/// BrowserSession owns this publisher on the main actor. Ordinary changes
/// remain synchronous; a nested batch publishes after its outer operation.
final class SessionChangeStream: Publisher {
    typealias Output = BrowserSession.Change
    typealias Failure = Never

    private let subject = PassthroughSubject<Output,Never>()
    private var depth = 0
    private var pending = Pending()

    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        subject.receive(subscriber:subscriber)
    }

    @MainActor
    func send(_ change:Output) {
        if depth == 0 { subject.send(change) }
        else { pending.add(change) }
    }

    @discardableResult
    @MainActor
    func batch<Value>(_ operation:() throws -> Value) rethrows -> Value {
        depth += 1
        defer {
            depth -= 1
            if depth == 0 {
                let events = pending.events
                // Clear before delivery: a subscriber may start another edit.
                pending = Pending()
                for event in events { subject.send(event) }
            }
        }
        return try operation()
    }

    private struct Pending {
        var spaces = false, structure = false, tabs = false
        var active = false, bookmarks = false
        var pages: [Tab] = []
        var pageIDs: Set<ObjectIdentifier> = []

        mutating func add(_ change:Output) {
            switch change {
            case .spaces: spaces = true
            case .structure: structure = true
            case .tabs: tabs = true
            case .activeTab: active = true
            case .bookmarks: bookmarks = true
            case .tab(let page):
                if pageIDs.insert(ObjectIdentifier(page)).inserted { pages.append(page) }
            }
        }

        var events: [Output] {
            var result: [Output] = []
            // Each stronger layout change already rebuilds the whole list.
            // Sending weaker changes afterward would restart row animations.
            if spaces { result.append(.spaces) }
            else if structure { result.append(.structure) }
            else if tabs { result.append(.tabs) }
            if bookmarks { result.append(.bookmarks) }
            if active { result.append(.activeTab) }
            result.append(contentsOf:pages.map(Output.tab))
            return result
        }
    }
}
