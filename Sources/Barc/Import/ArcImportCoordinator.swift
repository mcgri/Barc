import Foundation
import WebKit

struct ArcProfileInventory: Sendable {
    let profile: ArcProfile
    var history = 0
    var passwords = 0
    var cookies = 0

    static func read(_ snapshot: ArcSourceSnapshot) throws -> [ArcProfileInventory] {
        try snapshot.profiles.map { profile in
            let root = snapshot.profileURL(profile)
            var result = ArcProfileInventory(profile: profile)
            func count(_ filename: String, _ query: String) throws -> Int {
                let file = root.appending(path: filename)
                guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
                return Int(try SQLiteDatabase(readingOnly: file.path).query(query) { $0.integer(0) }.first ?? 0)
            }
            result.history = try count("History", "SELECT COUNT(*) FROM visits;")
            result.passwords = try count("Login Data", "SELECT COUNT(*) FROM logins WHERE blacklisted_by_user = 0 AND length(password_value) > 0;")
            let cookies = FileManager.default.fileExists(atPath: root.appending(path: "Network/Cookies").path) ? "Network/Cookies" : "Cookies"
            result.cookies = try count(cookies, "SELECT COUNT(*) FROM cookies;")
            return result
        }
    }
}

@MainActor
final class ArcImportCoordinator {
    private static var running = false
    struct PasswordAccess {
        var read: (Space.Identity) -> [PasswordCredential]
        var save: (ArcProfileReader.Password, Space.Identity, String) -> Bool
        var begin: () -> Void = {}
        static var keychain: PasswordAccess {
            PasswordAccess(read: { KeychainPasswordStore.all(identity: $0) }, save: { row, identity, sourceID in
                KeychainPasswordStore.save(host: row.host, username: row.username, password: row.value, identity: identity,
                    scheme: row.scheme, port: row.port, sourceID: sourceID, overwrite: false)
            }, begin: { KeychainPasswordStore.prepareForAccess() })
        }
    }

    private let session: BrowserSession
    private let settings: Settings
    private let downloads: DownloadManager
    private let reportDirectory: URL
    var progress: (String) -> Void = { _ in }
    var keyProvider: @Sendable () -> Data? = {
        ChromiumCookieCrypto.safeStoragePassword(service: "Arc Safe Storage", account: "Arc")
            .map(ChromiumCookieCrypto.deriveKey(password:))
    }
    private var approvedSourceKey: (root: URL, key: Data)?
    func clearSensitiveState() { approvedSourceKey = nil }
    var passwords: PasswordAccess = .keychain
    var storeProvider: (Space.Identity) -> WKWebsiteDataStore = { WebEnvironment.shared.dataStore(for: $0) }
    var autofillProvider: (Space.Identity) -> AutofillStore = { AutofillStore.forIdentity($0) }
    private(set) var reportURL: URL?

    init(session: BrowserSession, settings: Settings = .shared, downloads: DownloadManager = .shared,
         reportDirectory: URL = AppPaths.supportDirectory.appending(path: "Arc Imports")) {
        self.session = session; self.settings = settings; self.downloads = downloads; self.reportDirectory = reportDirectory
    }

    func run(_ source: ArcSourceSnapshot, options: ArcImportOptions) async throws -> ArcImportReport {
        guard !Self.running else { throw ArcImportFailure.alreadyRunning }
        guard options.sidebar || options.history || options.bookmarks || options.passwords || options.cookies || options.localStorage || options.supplementary else {
            throw ArcImportFailure.noSelection
        }
        guard !source.sidebarOnly || !(options.history || options.bookmarks || options.passwords || options.cookies || options.localStorage || options.supplementary) else {
            throw ArcImportFailure.incompleteSnapshot
        }
        Self.running = true
        defer { Self.running = false }
        let selected = source.profiles.filter { options.profileIDs.contains($0.folder) }
        guard !selected.isEmpty else { throw ArcImportFailure.noSelection }
        try Task.checkCancellation()
        let inventory = try await Task.detached { try ArcProfileInventory.read(source) }.value
        let built = ArcSpaceBuilder.build(source, options: options)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runID = UUID().uuidString.lowercased()
        let backup = reportDirectory.appending(path: runID + "-session-before.json")
        try JSONEncoder().encode(session.snapshot()).write(to: backup, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        var report = ArcImportReport()
        report.notes = [
            "Arc was read from a private snapshot and was not changed by the importer.",
            "Existing destination tabs, passwords, cookies and local-storage values are kept on a repeated import.",
            "Saved passwords and signed-in website sessions are separate. Some websites require signing in again.",
            "Passwords are encrypted in Barc's local vault. One macOS Keychain item protects its key; each profile keeps separate credential records.",
            "Partitioned cookies are skipped rather than changing their isolation. Cookie lifetimes are not extended.",
            "Tab URLs, titles, names and order are restored. Arc's back/forward stacks, scroll positions and in-page form state cannot be converted to WebKit state.",
            "Payment cards were not imported. Website databases, tab-scoped session storage, passkeys and extension data remain in Arc."
        ]
        var key: Data?
        if options.passwords || options.cookies {
            if let approvedSourceKey, approvedSourceKey.root == source.root { key = approvedSourceKey.key }
            else {
                approvedSourceKey = nil
                progress("Waiting for access to Arc's encryption key. Approve Arc Safe Storage in the macOS prompt if asked.")
                let provider = keyProvider
                key = await Task.detached { provider() }.value
                if let key { approvedSourceKey = (source.root, key) }
            }
            if key == nil { report.notes.append(ArcImportFailure.keyUnavailable.localizedDescription) }
        }
        if options.passwords { passwords.begin() }
        for (index, profile) in selected.enumerated() {
            progress("Importing \(profile.name) · \(index + 1) of \(selected.count)")
            let profileURL = source.profileURL(profile)
            let sourceKey = source.sourceFingerprint + "/" + profile.folder
            let profileSpaces = built.filter { $0.profile == profile.folder }
            guard let identity = profileSpaces.first?.snapshot.identity else { continue }
            let available = inventory.first { $0.profile.folder == profile.folder } ?? ArcProfileInventory(profile: profile)
            var result = ArcImportReport.Profile(name: profile.name, folder: profile.folder)
            if options.history {
                progress("Importing history · " + profile.name)
                do {
                    let visits = try await Task.detached { try ArcProfileReader.history(profileURL) }.value
                    guard let database = session.database(for: identity) else { throw ArcImportFailure.unreadable("destination history") }
                    let added = try await database.importArcVisits(visits, source: sourceKey)
                    let verified = try await database.verifyArcVisits(visits, source: sourceKey)
                    result.counts["History visits"] = .init(source: available.history, imported: added, existing: visits.count - added,
                        skipped: max(0, available.history - visits.count), verified: verified)
                } catch { result.counts["History visits"] = .init(source: available.history, failed: available.history); result.notes.append("History: " + error.localizedDescription) }
            }
            if options.bookmarks {
                do {
                    let records = try await Task.detached { try ArcProfileReader.bookmarks(profileURL) }.value
                    guard let database = session.database(for: identity) else { throw ArcImportFailure.unreadable("destination bookmarks") }
                    let before = try await database.bookmarks()
                    let existing = Set(before.map(\.url))
                    var seen = existing
                    let fresh = records.filter { seen.insert($0.url).inserted }
                    let added = try await database.importBookmarks(fresh.map { (url: $0.url, title: $0.title, folder: "From Arc/" + profile.name + "/" + $0.folder, date: $0.date) })
                    let after = Set(try await database.bookmarks().map(\.url))
                    result.counts["Bookmarks"] = .init(source: records.count, imported: added, existing: records.filter { existing.contains($0.url) }.count,
                        skipped: max(0, records.count - Set(records.map(\.url)).count), verified: records.filter { after.contains($0.url) }.count)
                } catch { result.notes.append("Bookmarks: " + error.localizedDescription); result.counts["Bookmarks"] = .init(failed: 1) }
            }
            if options.passwords {
                progress("Importing saved passwords · " + profile.name)
                if let key {
                    do {
                        let read = try await Task.detached { try ArcProfileReader.passwords(profileURL, key: key) }.value
                        result.counts["Saved passwords"] = transferPasswords(read, identity: identity, sourceKey: sourceKey)
                    } catch { result.counts["Saved passwords"] = .init(source: available.passwords, failed: available.passwords); result.notes.append("Saved passwords: " + error.localizedDescription) }
                } else { result.counts["Saved passwords"] = .init(source: available.passwords, failed: available.passwords) }
            }
            if options.localStorage {
                progress("Reading website local storage · " + profile.name)
                do {
                    let read = try await Task.detached { try ArcLocalStorageReader.read(profileURL) }.value
                    let transfer = ArcLocalStorageTransfer(store: storeProvider(identity))
                    result.counts["Website local-storage values"] = await transfer.transfer(read) { [weak self] done, total in
                        self?.progress("Website local storage · \(profile.name) · \(done) of \(total) websites")
                    }
                } catch { result.counts["Website local-storage values"] = .init(failed: 1); result.notes.append("Website local storage: " + error.localizedDescription) }
            }
            // Restore cookies after offscreen website storage setup finishes.
            if options.cookies {
                progress("Importing website cookies · " + profile.name)
                if let key {
                    do {
                        let read = try await Task.detached { try ArcProfileReader.cookies(profileURL, key: key) }.value
                        result.counts["Website cookies"] = await ArcCookieTransfer.transfer(read, to: storeProvider(identity))
                    } catch { result.counts["Website cookies"] = .init(source: available.cookies, failed: available.cookies); result.notes.append("Website cookies: " + error.localizedDescription) }
                } else { result.counts["Website cookies"] = .init(source: available.cookies, failed: available.cookies) }
            }
            var defaultSearch: String?
            if options.supplementary {
                progress("Importing addresses, searches and download history · " + profile.name)
                do {
                    let scope = ProfileDataPaths.key(for: identity)
                    let read = try await Task.detached { try ArcSupplementReader.read(profileURL, sourceID: sourceKey, profileName: profile.name, profileKey: scope) }.value
                    let addedAddresses = try autofillProvider(identity).importIdentities(read.addresses)
                    result.counts["Saved addresses"] = .init(source: read.addresses.count + read.unsupportedAddresses,
                        imported: addedAddresses, existing: read.addresses.count - addedAddresses, skipped: read.unsupportedAddresses, verified: read.addresses.count)
                    let knownSearches = Set(settings.customSearchEngines.map(\.id))
                    let newSearches = read.searchEngines.filter { !knownSearches.contains($0.id) }
                    settings.customSearchEngines += newSearches
                    result.counts["Search shortcuts"] = .init(source: read.searchEngines.count + read.unsupportedSearches,
                        imported: newSearches.count, existing: read.searchEngines.count - newSearches.count, skipped: read.unsupportedSearches,
                        verified: read.searchEngines.filter { candidate in settings.customSearchEngines.contains { $0.id == candidate.id } }.count)
                    let addedDownloads = try downloads.importArcRecords(read.downloads)
                    result.counts["Download records"] = .init(source: read.sourceDownloads, imported: addedDownloads,
                        existing: read.downloads.count - addedDownloads, skipped: read.sourceDownloads - read.downloads.count, verified: read.downloads.count)
                    result.counts["Generic form suggestions"] = .init(source: read.genericFormValues, skipped: read.genericFormValues)
                    defaultSearch = read.defaultSearchEngineID
                    if !read.searchEngines.isEmpty { result.notes.append("Search shortcuts use Barc's shared search-engine list.") }
                    result.notes.append(read.defaultSearchEngineID == nil
                        ? "Arc's default search engine could not be identified; the current Barc choice was kept."
                        : "The detected default search engine was restored for this profile's Spaces.")
                    if read.genericFormValues > 0 { result.notes.append("Barc supports saved addresses, but not Arc's arbitrary form-field suggestion history.") }
                } catch { result.notes.append("Additional data: " + error.localizedDescription); result.counts["Additional data"] = .init(failed: 1) }
            }
            var incoming = profileSpaces.map(\.snapshot)
            let beforeIcons = Set(session.spaces.flatMap(\.tabs).filter { $0.restoredFavicon != nil }.compactMap(\.importedSourceID))
            var expectedIcons: [String: PageFavicon] = [:]
            if options.sidebar {
                do {
                    let pages = incoming.flatMap { $0.tabs.map(\.url) }
                    let read = try await Task.detached { try ArcFaviconReader.read(profileURL, pages: pages) }.value
                    let githubBadge = try await Task.detached { try ArcFaviconReader.githubBadge(profileURL) }.value
                    for spaceIndex in incoming.indices {
                        var groups = incoming[spaceIndex].groups ?? []
                        for groupIndex in groups.indices where groups[groupIndex].symbolName == "arc.github.folder" {
                            groups[groupIndex].badgeIcon = githubBadge
                        }
                        incoming[spaceIndex].groups = groups
                        for tabIndex in incoming[spaceIndex].tabs.indices {
                            let url = incoming[spaceIndex].tabs[tabIndex].url
                            guard let key = PageFavicon.key(for: url), let data = read.icons[key] else { continue }
                            let icon = PageFavicon(pageURL: url, data: data)
                            incoming[spaceIndex].tabs[tabIndex].favicon = icon
                            if let sourceID = incoming[spaceIndex].tabs[tabIndex].importedSourceID { expectedIcons[sourceID] = icon }
                        }
                    }
                } catch { result.notes.append("Cached tab icons could not be read; normal icon discovery remains available.") }
            }
            for offset in incoming.indices {
                if let defaultSearch { incoming[offset].searchEngineID = defaultSearch }
                incoming[offset].bookmarkFolder = "From Arc/" + profile.name
                if !session.spaces.contains(where: { $0.id == incoming[offset].id }),
                   session.spaces.contains(where: { $0.name.localizedCaseInsensitiveCompare(incoming[offset].name) == .orderedSame }) {
                    incoming[offset].name += " (Arc)"
                }
            }
            let applied = try session.applyArcSpaces(incoming)
            if !expectedIcons.isEmpty {
                let actual = Dictionary(session.spaces.flatMap(\.tabs).compactMap { tab -> (String, PageFavicon)? in
                    guard let sourceID = tab.importedSourceID, let icon = tab.restoredFavicon else { return nil }
                    return (sourceID, icon)
                }, uniquingKeysWith: { first, _ in first })
                let matched = expectedIcons.filter { actual[$0.key] == $0.value }
                let existing = matched.keys.filter { beforeIcons.contains($0) }.count
                result.counts["Cached tab icons"] = .init(source: expectedIcons.count, imported: matched.count - existing,
                    existing: existing, skipped: expectedIcons.count - matched.count, verified: matched.count)
            }
            let tabs = incoming.reduce(0) { $0 + $1.tabs.count }
            let archive = incoming.reduce(0) { $0 + ($1.archivedTabs?.count ?? 0) }
            result.counts["Spaces"] = .init(source: incoming.count, imported: applied.spaces, existing: incoming.count - applied.spaces, verified: incoming.count)
            result.counts["Sidebar tabs"] = .init(source: tabs, imported: applied.tabs, existing: tabs - applied.tabs, verified: tabs)
            let folders = incoming.reduce(0) { $0 + ($1.groups?.count ?? 0) }
            let favorites = incoming.reduce(0) { $0 + ($1.pinnedSites?.count ?? 0) }
            result.counts["Folders"] = .init(source: folders, imported: applied.folders, existing: folders - applied.folders, verified: folders)
            result.counts["Favourites"] = .init(source: favorites, imported: applied.favorites, existing: favorites - applied.favorites, verified: favorites)
            result.counts["Archived tabs"] = .init(source: archive, imported: applied.archived, existing: archive - applied.archived, verified: archive)
            result.counts["Website databases (folders)"] = .init(source: source.unsupportedIndexedDBFolders[profile.folder] ?? 0, skipped: source.unsupportedIndexedDBFolders[profile.folder] ?? 0)
            result.counts["Extensions"] = .init(source: source.extensions[profile.folder] ?? 0, skipped: source.extensions[profile.folder] ?? 0)
            report.profiles.append(result)
            try save(report, runID: runID)
        }
        if let unassigned = built.first(where: { $0.profile == nil }) {
            let applied = try session.applyArcSpaces([unassigned.snapshot])
            let count = unassigned.snapshot.archivedTabs?.count ?? 0
            report.profiles.append(.init(name: unassigned.snapshot.name, folder: "unassigned-archive", counts: [
                "Archived tabs": .init(source: count, imported: applied.archived, existing: count - applied.archived, verified: count)
            ], notes: ["These entries belonged to deleted Arc Spaces. No account or website-session data was assigned to this Space."]))
        }
        if options.sidebar { try session.applyArcSpaceOrder(built.compactMap { $0.snapshot.id }) }
        if source.sidebar.skippedItems > 0 { report.notes.append("\(source.sidebar.skippedItems) Arc-specific or invalid sidebar/archive items could not be opened in Barc and remain in Arc.") }
        report.finishedAt = Date(); report.completed = true
        try save(report, runID: runID)
        progress(report.summary)
        return report
    }

    private func transferPasswords(_ input: ArcProfileReader.ReadResult<ArcProfileReader.Password>, identity: Space.Identity, sourceKey: String) -> ArcImportReport.Count {
        var result = ArcImportReport.Count(source: input.source, skipped: input.skipped, failed: input.failed)
        let existing = Dictionary(passwords.read(identity).compactMap { row in row.storagePath.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        var expected: [(ArcProfileReader.Password, String)] = []
        for row in input.records {
            let id = sourceKey + "/login/" + String(row.id)
            let path = KeychainPasswordStore.path(for: identity, sourceID: id)
            if let retained = existing[path] {
                result.existing += 1
                if retained.host == row.host, retained.username == row.username, retained.password == row.value,
                   retained.scheme == row.scheme, retained.port == row.port { result.verified += 1 }
                continue
            }
            if passwords.save(row, identity, id) { expected.append((row, path)) }
            else { result.failed += 1 }
        }
        let actual = Dictionary(passwords.read(identity).compactMap { row in row.storagePath.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        for (source, path) in expected {
            guard let saved = actual[path], saved.host == source.host, saved.username == source.username, saved.password == source.value,
                  saved.scheme == source.scheme, saved.port == source.port else {
                result.failed += 1; continue
            }
            result.imported += 1; result.verified += 1
        }
        return result
    }

    private func save(_ report: ArcImportReport, runID: String) throws {
        let url = reportDirectory.appending(path: runID + "-result.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        reportURL = url
    }
}
