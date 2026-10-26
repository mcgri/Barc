// Modified for Barc: complete memory accounting and explicit process attribution, 2026-10-26.
import AppKit
import Testing
@testable import Barc

@Suite("Performance memory breakdown")
@MainActor
struct PerformanceMemoryBreakdownTests {
    private let mib: UInt64 = 1_048_576

    @Test("Networking and auxiliary pages appear in the chart and every byte is accounted for")
    func completeComposition() {
        var snapshot = ResourceSnapshot()
        snapshot.browserMemoryBytes = 139 * mib
        snapshot.webContentMemoryBytes = 484 * mib
        snapshot.auxiliaryContentMemoryBytes = 185 * mib
        snapshot.networkProcessMemoryBytes = 15 * mib
        snapshot.gpuProcessMemoryBytes = 38 * mib
        let slices = ActivityMath.memorySlices(of: snapshot)
        #expect(slices.map(\.label) == ["Barc", "Tabs and WebKit", "Other web content", "Networking", "Graphics"])
        #expect(slices.reduce(0) { $0 + UInt64($1.value) } == snapshot.totalMemoryBytes)
        #expect(abs(slices.reduce(0) { $0 + $1.fraction } - 1) < 0.000001)
    }

    @Test("Shared page memory is labelled and the full process is counted only once")
    func sharedProcess() {
        let first = usage(sharedPages: 2), second = usage(sharedPages: 2)
        #expect(first.formattedProcessMemory == "Shared 480.0 MB")
        #expect(first.memoryExplanation.contains("2 pages"))
        #expect(first.memoryExplanation.contains("individual page allocations are not available"))
        #expect(ActivityMath.rollup(of: [first, second]).memoryBytes == 480 * mib)
        #expect(first.memoryBytes == 480 * mib, "Do not invent an equal per-tab allocation")
    }

    @Test("An exclusive process still includes the engine; sleeping and unknown readings stay distinct")
    func memoryMeaning() {
        #expect(usage().formattedProcessMemory == "480.0 MB")
        #expect(usage().memoryExplanation.contains("including the engine"))
        #expect(usage(measured: false).formattedProcessMemory == "Unavailable")
        #expect(usage(suspended: true).formattedProcessMemory == "Suspended")
    }

    @Test("The window and embedded pane explain the engine limit and separate the helper categories")
    func visibleBreakdown() throws {
        let session = TestSession.make().0
        for presentation in [TaskManagerViewController.Presentation.window, .embedded] {
            let controller = TaskManagerViewController(session: session, presentation: presentation, snapshotProvider: { _ in
                var snapshot = ResourceSnapshot()
                snapshot.browserMemoryBytes = 139 * self.mib
                snapshot.webContentMemoryBytes = 484 * self.mib
                snapshot.auxiliaryContentMemoryBytes = 185 * self.mib
                snapshot.networkProcessMemoryBytes = 15 * self.mib
                snapshot.gpuProcessMemoryBytes = 38 * self.mib
                snapshot.tabs = [self.usage(), self.usage(suspended: true)]
                return snapshot
            })
            controller.loadView()
            let text = labels(controller.view).joined(separator: "\n")
            #expect(text.contains("BROWSER AND ENGINE MEMORY"))
            #expect(text.contains("Barc app"))
            #expect(text.contains("WebKit engine baseline"))
            #expect(text.contains("Included with tab processes"))
            #expect(text.contains("Networking"))
            #expect(text.contains("Other web content"))
            #expect(text.contains("185 MB"))
            #expect(text.contains("exact tab-only memory are not available"))
            #expect(tables(controller.view).contains { $0.tableColumns.contains { $0.title == "Process RAM" } })
            if let directory = ProcessInfo.processInfo.environment["BARC_PERFORMANCE_PREVIEW_DIR"] {
                let name: String
                let width: CGFloat
                switch presentation {
                case .window: name = "window"; width = 980
                case .embedded: name = "embedded"; width = 680
                }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1300),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentViewController = controller
                window.setContentSize(NSSize(width: width, height: 1300))
                controller.view.layoutSubtreeIfNeeded()
                let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("performance-\(name).png"))
                window.contentViewController = nil
            }
        }
    }

    private func usage(sharedPages: Int = 1, measured: Bool = true, suspended: Bool = false) -> TabResourceUsage {
        TabResourceUsage(tabId: UUID(), title: "Example", url: nil, domain: "example.test", spaceName: "Work",
            isSuspended: suspended, isPlayingAudio: false, pid: suspended ? nil : 123,
            memoryBytes: suspended ? 0 : 480 * mib, cpuPercentage: 0, isMemoryHog: false, isCpuHog: false,
            hasMeasuredMemory: measured, processPageCount: sharedPages)
    }

    private func labels(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(labels)
    }

    private func tables(_ view: NSView) -> [NSTableView] {
        ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
    }
}
