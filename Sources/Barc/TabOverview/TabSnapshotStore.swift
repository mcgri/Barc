import AppKit
import WebKit

/// In-memory cache and capture manager for tab preview snapshots.
///
/// Used by the Safari-style Tab Overview grid to render visual thumbnail cards
/// of open tabs. Snapshots are captured asynchronously when tabs finish loading,
/// when tabs are deactivated, or on demand when Tab Overview opens.
@MainActor
final class TabSnapshotStore {
    static let shared = TabSnapshotStore()

    /// Thumbnails are drawn a few hundred points wide, so that is the width
    /// they are captured at: WebKit renders the page scaled, and the image
    /// costs about a megabyte instead of the twenty-five a full Retina
    /// window would.
    static let captureWidth: CGFloat = 480

    /// How many tabs keep a thumbnail. Beyond this the least recently used
    /// goes; the overview captures a missing one on demand.
    let capacity: Int
    let byteLimit: Int
    private(set) var totalCost = 0
    private var costs: [UUID: Int] = [:]
    private var captures: Set<UUID> = []
    private var generation = 0
    private var removedDuringCapture: Set<UUID> = []

    private var snapshots: [UUID: NSImage] = [:]
    /// Most recently used last.
    private var order: [UUID] = []

    init(capacity: Int = 30, byteLimit: Int = 24 * 1024 * 1024) {
        self.capacity = max(0, capacity)
        self.byteLimit = max(0, byteLimit)
    }

    /// Retrieves any cached snapshot for the given tab ID.
    func snapshot(for tabID: UUID) -> NSImage? {
        guard let image = snapshots[tabID] else { return nil }
        touch(tabID)
        return image
    }

    /// Stores an explicit snapshot for the given tab ID (useful for testing and manual caching).
    func setSnapshot(_ image: NSImage, for tabID: UUID) {
        let cost = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .reduce(0) { $0 + $1.bytesPerRow * $1.pixelsHigh }
        let estimated = cost > 0 ? cost : Int(max(0, image.size.width) * max(0, image.size.height) * 16)
        totalCost -= costs[tabID] ?? 0
        snapshots[tabID] = image
        costs[tabID] = estimated
        totalCost += estimated
        touch(tabID)
        while (order.count > capacity || totalCost > byteLimit), let oldest = order.first {
            removeSnapshot(for: oldest)
        }
    }

    /// Removes the snapshot for a closed tab.
    func removeSnapshot(for tabID: UUID) {
        snapshots.removeValue(forKey: tabID)
        totalCost -= costs.removeValue(forKey: tabID) ?? 0
        if captures.contains(tabID) { removedDuringCapture.insert(tabID) }
        order.removeAll { $0 == tabID }
    }

    /// Clears all cached snapshots.
    func clear() {
        generation += 1
        snapshots.removeAll()
        costs.removeAll()
        totalCost = 0
        order.removeAll()
    }

    private func touch(_ tabID: UUID) {
        order.removeAll { $0 == tabID }
        order.append(tabID)
    }

    /// Number of cached snapshots.
    var count: Int {
        snapshots.count
    }

    /// Captures a snapshot of the tab's web view if available and visible.
    ///
    /// If snapshot capture succeeds, the image is automatically cached and returned.
    /// If the tab has no loaded web view or is off-screen / 0-sized, returns nil.
    @discardableResult
    func capture(tab: Tab) async -> NSImage? {
        guard let webView = tab.currentWebView else { return nil }
        return await capture(webView: webView, for: tab.id)
    }

    /// Captures `webView` at thumbnail width and files it under `id`.
    @discardableResult
    func capture(webView: WKWebView, for id: UUID) async -> NSImage? {
        guard webView.bounds.width > 0, webView.bounds.height > 0,
              captures.insert(id).inserted else { return snapshot(for: id) }
        let captureGeneration = generation
        defer { captures.remove(id); removedDuringCapture.remove(id) }
        do {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: Double(min(Self.captureWidth, webView.bounds.width)))
            let image = try await webView.takeSnapshot(configuration: configuration)
            guard generation == captureGeneration, !removedDuringCapture.contains(id), !Task.isCancelled else { return nil }
            setSnapshot(image, for: id)
            return image
        } catch {
            return nil
        }
    }
}
