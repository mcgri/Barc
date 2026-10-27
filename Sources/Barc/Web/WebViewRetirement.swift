import AppKit
import WebKit

/// A system editing panel can retain a WKWebView after its tab releases it.
/// Normally the weak entry disappears immediately. If the view survives, give
/// it an empty document and history so it cannot retain the sleeping page.
/// The owner captures its restoration state before calling `retire`.
@MainActor
final class WebViewRetirement {
    static let shared = WebViewRetirement()

    private final class Deadline: NSObject {
        let uptime: TimeInterval
        init(_ uptime: TimeInterval) { self.uptime = uptime }
    }
    private let pending = NSMapTable<WKWebView, Deadline>.weakToStrongObjects()
    private var cleanup: Task<Void, Never>?
    private let uptime: () -> TimeInterval
    private let delay: TimeInterval

    /// WebKit ignores states with no current history item. Use a session
    /// containing one loaded blank page, and reuse its immutable state.
    private var emptyState: Any?

    init(delay: TimeInterval = 2, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.delay = delay
        self.uptime = uptime
    }

    func retire(_ view: WKWebView) {
        WebEnvironment.shared.markRetired(true, view: view)
        pending.setObject(Deadline(uptime() + delay), forKey: view)
        scheduleCleanup()
    }

    /// Handoffs to a new owner revoke any earlier retirement request.
    func claim(_ view: WKWebView) {
        WebEnvironment.shared.markRetired(false, view: view)
        pending.removeObject(forKey: view)
    }

    private func scheduleCleanup() {
        guard cleanup == nil,
              let next = pending.keyEnumerator().allObjects.compactMap({ key -> TimeInterval? in
                  guard let view = key as? WKWebView else { return nil }
                  return pending.object(forKey: view)?.uptime
              }).min() else { return }
        let wait = max(0, next - uptime())
        cleanup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard let self else { return }
            await self.releaseRetainedDocuments()
            self.cleanup = nil
            self.scheduleCleanup()
        }
    }

    /// One coalesced cleanup for surviving views, with no repeating idle poll.
    func releaseRetainedDocuments() async {
        let now = uptime()
        for view in pending.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) {
            guard let deadline = pending.object(forKey: view), deadline.uptime <= now else { continue }
            guard view.superview == nil, view.window == nil else {
                pending.removeObject(forKey: view)
                WebEnvironment.shared.markRetired(false, view: view)
                continue
            }
            guard let state = await blankState() else {
                if pending.object(forKey: view) === deadline {
                    pending.setObject(Deadline(uptime() + 30), forKey: view)
                }
                continue
            }
            // A handoff or reattachment during preparation revokes cleanup.
            guard pending.object(forKey: view) === deadline,
                  view.superview == nil, view.window == nil else { continue }
            pending.removeObject(forKey: view)
            view.stopLoading()
            view.interactionState = state
        }
    }

    private func blankState() async -> Any? {
        if let emptyState { return emptyState }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let blank = WKWebView(frame: .zero, configuration: configuration)
        blank.load(URLRequest(url: URL(string: "data:text/html,%3C!doctype%20html%3E%3Ctitle%3E%3C/title%3E")!))
        defer { blank.stopLoading() }
        for _ in 0..<100 {
            if !blank.isLoading, blank.backForwardList.currentItem != nil {
                emptyState = blank.interactionState
                return emptyState
            }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
        }
        return nil
    }
}
