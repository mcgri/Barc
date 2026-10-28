import AppKit
import Darwin

/// Coalesces activation and pressure bursts without scheduling repeated allocator scans.
struct MemoryReliefSchedule {
    private(set) var lastRequest: TimeInterval?

    mutating func accept(at time: TimeInterval) -> Bool {
        if let lastRequest, time - lastRequest < 180 { return false }
        lastRequest = time
        return true
    }
}

/// Returns freed-but-dirty allocator pages that still count toward process footprint.
/// A long-running sample held 230 MB in WebKit Malloc with only about 10 MB live.
/// Relief can release unused pages; it cannot release live WebKit objects.
@MainActor
public final class MemoryRelief {
    public static let shared = MemoryRelief()
    private var source: DispatchSourceMemoryPressure?
    private var resignObserver: NSObjectProtocol?
    private var schedule = MemoryReliefSchedule()

    private init() {}

    /// Installs one pressure source and one application lifecycle observer.
    public func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.requestRelief() }
        }
        self.source = source
        source.resume()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.requestRelief() }
        }
    }

    /// Runs at most once every three minutes, away from UI work.
    public func requestRelief() {
        guard schedule.accept(at: ProcessInfo.processInfo.systemUptime) else { return }
        DispatchQueue.global(qos: .utility).async {
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
