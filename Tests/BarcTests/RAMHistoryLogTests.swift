#if BARC_LOCAL_RAM_LOG
import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

/// Run with `make test-ramlog`. A plain `swift test` does not compile these,
/// because the code they test is not in the build.
@Suite("Local RAM history log", .serialized)
@MainActor
struct RAMHistoryLogTests {
    private let mb: UInt64 = 1_048_576

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "barc-ram-\(UUID())", directoryHint: .isDirectory)
    }

    private func usage(_ host: String, pid: pid_t?, memory: UInt64, id: UUID = UUID(), asleep: Bool = false) -> TabResourceUsage {
        TabResourceUsage(tabId: id, title: "A secret title", url: URL(string: "https://\(host)/inbox?token=abc"), domain: host,
                         spaceName: "Work", isSuspended: asleep, isPlayingAudio: false, pid: pid,
                         memoryBytes: memory, cpuPercentage: 1, isMemoryHog: false, isCpuHog: false)
    }

    private func sample(_ snapshot: ResourceSnapshot, privateTabs: Set<UUID> = []) -> RAMHistoryLog.Sample {
        RAMHistoryLog.makeSample(snapshot, time: "t", privateTabs: privateTabs, auxiliaryPages: [:], peak: { _ in nil },
                                 swapUsedMB: nil, pressure: nil, sampleMS: 0)
    }

    @Test("Tabs sharing a process make one row, heaviest first, and sleeping tabs are only counted")
    func sharedProcess() {
        var snapshot = ResourceSnapshot()
        snapshot.tabs = [usage("a.example", pid: 100, memory: 300 * mb), usage("b.example", pid: 100, memory: 300 * mb),
                         usage("c.example", pid: 200, memory: 900 * mb), usage("d.example", pid: nil, memory: 0, asleep: true)]
        let row = sample(snapshot)
        #expect(row.processes.map(\.pid) == [200, 100])
        #expect(row.processes[1].memoryMB == 300)
        #expect(row.processes[1].pages.map(\.host) == ["a.example", "b.example"])
        #expect(row.awakeTabs == 3)
        #expect(row.sleepingTabs == 1)
    }

    @Test("A private page's site, and any title or address, never reach the row")
    func privacy() throws {
        let hidden = UUID()
        var snapshot = ResourceSnapshot()
        snapshot.tabs = [usage("secret.example", pid: 100, memory: mb, id: hidden), usage("open.example", pid: 200, memory: mb)]
        let text = try #require(String(data: JSONEncoder().encode(sample(snapshot, privateTabs: [hidden])), encoding: .utf8))
        #expect(!text.contains("secret.example"))
        #expect(!text.contains("A secret title"))
        #expect(!text.contains("token"))
        #expect(!text.contains("inbox"))
        #expect(text.contains("open.example"))
    }

    /// Glances and panels are not tabs, and one can belong to a private
    /// session. The ordinary page is the control: it shows the site really
    /// would have been written.
    @Test("A private page outside any tab keeps its site out of the log")
    func privateViewOutsideTabs() async throws {
        _ = NSApplication.shared
        let fixture = try MemoryHTTPFixture()
        let address = try await fixture.start()
        defer { fixture.stop() }
        let secret = WebEnvironment.shared.makeWebView(identity: .makeEphemeral(), purpose: .preview)
        let ordinary = WebEnvironment.shared.makeWebView(identity: .standard, purpose: .panel)
        for view in [secret, ordinary] {
            view.load(URLRequest(url: address))
            for _ in 0..<500 {
                try await Task.sleep(for: .milliseconds(10))
                if !view.isLoading, (try? await view.evaluateJavaScript("!!document.getElementById('httpReady')")) as? Bool == true { break }
            }
        }
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = RAMHistoryLog(directory: directory).sample(TestSession.make().0)
        let secretPID = try #require(TabResourceMonitor.contentProcessID(secret))
        let ordinaryPID = try #require(TabResourceMonitor.contentProcessID(ordinary))
        #expect(secretPID != ordinaryPID)
        #expect(row.processes.first { $0.pid == secretPID }?.pages.map(\.host) == ["private"])
        let shown = try #require(row.processes.first { $0.pid == ordinaryPID }?.pages.first?.host)
        #expect(shown.contains("127.0.0.1"))
    }

    @Test("Each local day gets its own file, readable only by this account")
    func dailyFiles() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 23, minute: 59)))
        let log = RAMHistoryLog(directory: directory, now: { date })
        let session = TestSession.make().0
        log.sample(session)
        date = date.addingTimeInterval(120)
        log.sample(session)
        log.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["2026-03-01.jsonl", "2026-03-02.jsonl"])
        let file = directory.appending(path: "2026-03-02.jsonl")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("Old day files go and nothing else in the folder is touched")
    func retention() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["2026-01-01.jsonl", "2026-02-20.jsonl", "notes.txt", "backup.jsonl"] {
            try Data().write(to: directory.appending(path: name))
        }
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12)))
        let log = RAMHistoryLog(directory: directory, now: { date })
        log.prune(before: date)
        log.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
                == ["2026-02-20.jsonl", "backup.jsonl", "notes.txt"])
    }

    @Test("A real sample measures the browser, and launch and quit rows bracket it")
    func realSession() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RAMHistoryLog(directory: directory)
        let session = TestSession.make().0
        log.start(session: session)
        let row = log.sample(session)
        log.stop()
        #expect(row.uiMB > 0)
        #expect(row.totalMB >= row.uiMB)
        #expect((row.uiPeakMB ?? 0) >= row.uiMB)
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path).first)
        let lines = try String(contentsOf: directory.appending(path: name), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains(RAMHistoryLog.marker))
        #expect(lines[1].contains("\"event\":\"sample\""))
        #expect(lines[2].contains("\"event\":\"quit\""))
    }
}
#endif
