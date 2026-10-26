import Foundation
import AppKit

/// Snapshot of resource consumption for a single tab.
public struct TabResourceUsage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let tabId: UUID
    public let title: String
    public let url: URL?
    public let domain: String
    public let spaceName: String
    /// Which space the tab is in, for the per-space rollups. Optional so a
    /// reading taken without a session to hand -- a test, a tab already gone
    /// by the time the sweep reached it -- is still a valid one.
    public let spaceID: UUID?
    public let isSuspended: Bool
    public let isPlayingAudio: Bool
    public let pid: pid_t?
    public let hasMeasuredMemory: Bool
    /// Number of live pages known to use this process, including auxiliary views.
    public let processPageCount: Int
    public let automaticSleepExplanation: String
    public let memoryBytes: UInt64
    public let cpuPercentage: Double
    public let isMemoryHog: Bool
    public let isCpuHog: Bool

    public init(
        tabId: UUID,
        title: String,
        url: URL?,
        domain: String,
        spaceName: String,
        spaceID: UUID? = nil,
        isSuspended: Bool,
        isPlayingAudio: Bool,
        pid: pid_t?,
        memoryBytes: UInt64,
        cpuPercentage: Double,
        isMemoryHog: Bool,
        isCpuHog: Bool,
        hasMeasuredMemory: Bool = true,
        processPageCount: Int = 1,
        automaticSleepExplanation: String = "Waiting for idle check"
    ) {
        self.id = tabId
        self.tabId = tabId
        self.title = title.isEmpty ? "Untitled" : title
        self.url = url
        self.domain = domain
        self.spaceName = spaceName
        self.spaceID = spaceID
        self.isSuspended = isSuspended
        self.isPlayingAudio = isPlayingAudio
        self.pid = pid
        self.hasMeasuredMemory = hasMeasuredMemory
        self.processPageCount = max(1, processPageCount)
        self.automaticSleepExplanation = isSuspended ? "Asleep" : automaticSleepExplanation
        self.memoryBytes = memoryBytes
        self.cpuPercentage = max(0.0, cpuPercentage)
        self.isMemoryHog = isMemoryHog
        self.isCpuHog = isCpuHog
    }

    public var formattedMemory: String {
        if isSuspended {
            return "Suspended"
        }
        guard hasMeasuredMemory else { return "Unavailable" }
        let mb = Double(memoryBytes) / (1024 * 1024)
        if mb >= 1024 {
            let gb = mb / 1024
            return String(format: "%.2f GB", gb)
        }
        return String(format: "%.1f MB", mb)
    }

    public var formattedCPU: String {
        if isSuspended {
            return "0.0%"
        }
        guard hasMeasuredMemory else { return "Unavailable" }
        return String(format: "%.1f%%", cpuPercentage)
    }

    public var formattedProcessMemory: String {
        guard !isSuspended, hasMeasuredMemory else { return formattedMemory }
        return processPageCount > 1 ? "Shared \(formattedMemory)" : formattedMemory
    }

    public var memoryExplanation: String {
        if isSuspended { return "Sleeping; no live page process. Saved tab information remains in Barc." }
        guard hasMeasuredMemory else { return "The process memory reading is unavailable." }
        if processPageCount > 1 {
            return "Total for a process shared by \(processPageCount) pages, including WebKit and caches. Counted once in browser totals; individual page allocations are not available."
        }
        return "Memory of this tab's WebKit process, including the engine and caches. WebKit does not report the tab's separate allocation."
    }
}
