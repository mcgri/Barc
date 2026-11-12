#if BARC_LOCAL_RAM_LOG
import AppKit
import Darwin
import Foundation
import WebKit

/// A daily history of where Barc's memory goes, for debugging on this Mac.
///
/// Never in a release. Everything here is behind `BARC_LOCAL_RAM_LOG`, which
/// only `make ... RAM_LOG=1` defines, so a release binary holds none of this
/// code and there is no setting that could turn it on. The Makefile refuses
/// the flag on CI or with a signing identity, and
/// `Tools/package-unsigned-release.sh` fails if `marker` turns up in what it
/// packages.
///
/// One sample a minute goes to `ram-history/<local day>.jsonl` beside the
/// profile. `Tools/ram-report.py` reads them back. A sample keeps site names
/// only, never titles or full addresses, and a private page's site is never
/// written at all.
@MainActor
final class RAMHistoryLog {
    static let shared = RAMHistoryLog()

    /// In every launch row, and what packaging searches a release binary for.
    nonisolated static let marker = "barc-local-ram-log"
    static let sampleInterval: TimeInterval = 60
    static let retentionDays = 30

    struct Page: Codable, Equatable {
        var host: String
        var space: String
        /// Why the page is awake, in the Task Manager's words.
        var state: String
    }

    struct Process: Codable, Equatable {
        var kind: String
        var pid: Int32
        var memoryMB: Double
        /// The most this process has ever used. A sample a minute misses a
        /// short spike; this does not.
        var peakMB: Double?
        var cpu: Double?
        var pages: [Page]
    }

    struct Sample: Codable, Equatable {
        var event = "sample"
        var time: String
        var totalMB: Double
        /// Barc's own process: the UI and everything that is not a page.
        var uiMB: Double
        var uiPeakMB: Double?
        var pagesMB: Double
        var gpuMB: Double
        var networkMB: Double
        var auxiliaryMB: Double
        var cpu: Double
        var awakeTabs: Int
        var sleepingTabs: Int
        /// Something could not be read, so the totals are a floor.
        var incomplete: Bool
        var swapUsedMB: Double?
        /// 1 normal, 2 warning, 4 critical.
        var pressure: Int?
        /// What taking this sample cost, on the main thread.
        var sampleMS: Double
        var processes: [Process]
    }

    private struct Launch: Encodable {
        var event = "launch"
        var time: String
        var log = RAMHistoryLog.marker
        var version: String
        var build: String
        var physicalMemoryMB: Double
    }

    private struct Quit: Encodable {
        var event = "quit"
        var time: String
    }

    /// Its own monitor: `snapshot` feeds the history behind the Task Manager's
    /// graphs, and CPU is a difference between two readings, so sharing
    /// `TabResourceMonitor.shared` would disturb both.
    private let monitor = TabResourceMonitor()
    private let directory: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "barc.ram-history", qos: .utility)
    private var timer: Timer?
    private weak var session: BrowserSession?
    private var lastDay: String?

    private let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()
    private let timeFormat: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.timeZone = .current
        return format
    }()

    init(directory: URL = AppPaths.supportDirectory.appending(path: "ram-history", directoryHint: .isDirectory),
         now: @escaping () -> Date = { .now }) {
        self.directory = directory
        self.now = now
    }

    func start(session: BrowserSession) {
        guard timer == nil else { return }
        self.session = session
        let info = Bundle.main.infoDictionary
        write(Launch(time: timeFormat.string(from: now()),
                     version: info?["CFBundleShortVersionString"] as? String ?? "?",
                     build: info?["CFBundleVersion"] as? String ?? "?",
                     physicalMemoryMB: Self.megabytes(ProcessInfo.processInfo.physicalMemory)))
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                self.sample(session)
            }
        }
        timer.tolerance = 10
        // Common modes, so a held menu or a drag leaves no gap in the day.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Waits for the queue, so the last rows are on disk before Barc exits.
    func stop() {
        timer?.invalidate()
        timer = nil
        write(Quit(time: timeFormat.string(from: now())))
        queue.sync {}
    }

    @discardableResult
    func sample(_ session: BrowserSession) -> Sample {
        let clock = ContinuousClock()
        let started = clock.now
        let snapshot = monitor.snapshot(in: session)
        let privateTabs = Set(session.allTabs.filter(\.isPrivate).map(\.id))
        let auxiliary = Self.auxiliaryPages(of: snapshot.auxiliaryProcesses)
        let elapsed = started.duration(to: clock.now).components
        let sample = Self.makeSample(
            snapshot,
            time: timeFormat.string(from: now()),
            privateTabs: privateTabs,
            auxiliaryPages: auxiliary,
            peak: Self.lifetimePeak(pid:),
            swapUsedMB: Self.swapUsed(),
            pressure: Self.pressure(),
            sampleMS: (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15).rounded()
        )
        write(sample)
        return sample
    }

    // MARK: - Rows

    /// Pure, so what reaches the disk is a test rather than a promise.
    static func makeSample(
        _ snapshot: ResourceSnapshot,
        time: String,
        privateTabs: Set<UUID>,
        auxiliaryPages: [pid_t: [String]],
        peak: (pid_t) -> UInt64?,
        swapUsedMB: Double?,
        pressure: Int?,
        sampleMS: Double
    ) -> Sample {
        // One row per process, not per tab: tabs sharing a process all report
        // its whole memory, and adding those up would multiply it.
        var pagesByProcess: [pid_t: [TabResourceUsage]] = [:]
        for usage in snapshot.tabs where !usage.isSuspended {
            if let pid = usage.pid { pagesByProcess[pid, default: []].append(usage) }
        }
        var processes = pagesByProcess.map { pid, usages -> Process in
            Process(kind: "page", pid: pid, memoryMB: megabytes(usages[0].memoryBytes),
                    peakMB: peak(pid).map(megabytes), cpu: rounded(usages[0].cpuPercentage),
                    pages: usages.map { usage in
                        let hidden = privateTabs.contains(usage.tabId)
                        return Page(host: hidden ? "private" : (usage.domain.isEmpty ? "(no site)" : usage.domain),
                                    space: hidden ? "private" : usage.spaceName,
                                    state: usage.automaticSleepExplanation)
                    }.sorted { ($0.host, $0.state) < ($1.host, $1.state) })
        }
        processes += snapshot.auxiliaryProcesses.map { process in
            Process(kind: "auxiliary", pid: process.pid, memoryMB: megabytes(process.memoryBytes ?? 0),
                    peakMB: peak(process.pid).map(megabytes), cpu: nil,
                    pages: (auxiliaryPages[process.pid] ?? []).map { Page(host: $0, space: "", state: "") })
        }
        processes.sort { ($0.memoryMB, $1.pid) > ($1.memoryMB, $0.pid) }
        return Sample(
            time: time,
            totalMB: megabytes(snapshot.totalMemoryBytes),
            uiMB: megabytes(snapshot.browserMemoryBytes),
            uiPeakMB: peak(getpid()).map(megabytes),
            pagesMB: megabytes(snapshot.webContentMemoryBytes),
            gpuMB: megabytes(snapshot.gpuProcessMemoryBytes),
            networkMB: megabytes(snapshot.networkProcessMemoryBytes),
            auxiliaryMB: megabytes(snapshot.auxiliaryContentMemoryBytes),
            cpu: rounded(snapshot.totalCpuPercentage),
            awakeTabs: snapshot.activeTabCount,
            sleepingTabs: snapshot.suspendedTabCount,
            incomplete: snapshot.hasUnmeasuredProcesses,
            swapUsedMB: swapUsedMB,
            pressure: pressure,
            sampleMS: sampleMS,
            processes: processes
        )
    }

    /// Panels, Glance and web apps are described by `WebEnvironment`, which
    /// names the site. A view whose identity cannot be proved to be a normal
    /// profile is treated as private.
    private static func auxiliaryPages(of processes: [AuxiliaryProcessUsage]) -> [pid_t: [String]] {
        let wanted = Set(processes.map(\.pid))
        var pages: [pid_t: Set<String>] = [:]
        for view in WebEnvironment.shared.liveWebViews {
            guard let pid = TabResourceMonitor.contentProcessID(view), wanted.contains(pid) else { continue }
            let identity = WebEnvironment.shared.identity(for: view.configuration.websiteDataStore)
            let hidden = identity?.isPrivate ?? true
            pages[pid, default: []].insert(hidden ? "private" : WebEnvironment.shared.resourceDescription(for: view))
        }
        return pages.mapValues { $0.sorted() }
    }

    static func megabytes(_ bytes: UInt64) -> Double { rounded(Double(bytes) / 1_048_576) }
    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    // MARK: - Readings

    private static func lifetimePeak(pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? usage.ri_lifetime_max_phys_footprint : nil
    }

    private static func swapUsed() -> Double? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? megabytes(swap.xsu_used) : nil
    }

    private static func pressure() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : nil
    }

    // MARK: - Files

    /// A diagnostic: every failure is swallowed, because losing a row must
    /// never affect the browser. The disk work stays off the main thread.
    private func write(_ row: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(row) else { return }
        line.append(0x0A)
        let date = now()
        let day = dayFormat.string(from: date)
        let file = directory.appending(path: "\(day).jsonl")
        let directory = directory
        queue.async {
            let manager = FileManager.default
            // Which sites were open is close to history: for this account only.
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            if !manager.fileExists(atPath: file.path) {
                manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
        if day != lastDay {
            lastDay = day
            prune(before: date)
        }
    }

    /// Only ever touches day files in this folder.
    func prune(before date: Date) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: date) else { return }
        let oldest = dayFormat.string(from: cutoff)
        let directory = directory
        queue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.range(of: #"^\d{4}-\d{2}-\d{2}\.jsonl$"#, options: .regularExpression) != nil {
                // ISO dates sort as text.
                if name.prefix(10) < oldest {
                    try? FileManager.default.removeItem(at: directory.appending(path: name))
                }
            }
        }
    }

    /// For tests: everything queued is on disk.
    func flush() { queue.sync {} }
}
#endif
