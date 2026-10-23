// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import Foundation

/// The running app's identity, read from the bundle.
enum AppInfo {
    static let name = "Barc"
    static let website = URL(string: "https://github.com/mcgri/Barc")!
    static let upstreamWebsite = URL(string: "https://github.com/kylmora/kylmora")!

    static var licenseURL: URL {
        Bundle.main.url(forResource: "LICENSE", withExtension: nil)
            ?? website.appending(path: "blob/main/LICENSE")
    }

    static var noticeURL: URL {
        Bundle.main.url(forResource: "NOTICE", withExtension: nil)
            ?? website.appending(path: "blob/main/NOTICE")
    }

    /// `CFBundleShortVersionString`, the version people see.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `CFBundleVersion`, the build number.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

/// A dotted version, compared numerically: 0.10.0 is newer than 0.9.1, and
/// 1.0 equals 1.0.0. Anything after a hyphen or plus (a prerelease tag or
/// build metadata) is ignored, so 1.0.0-beta compares as 1.0.0.
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let parts: [Int]
    let text: String

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        parts = numeric.split(separator: ".").map { Int($0) ?? 0 }
        self.text = trimmed
    }

    var description: String { text }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// Checks a configured Barc release feed. Local builds have no update feed and
/// return an explanatory status without making a network request.
enum UpdateCheck {
    // A fork must not offer packages from its upstream browser's update feed.
    // Configure a Barc-owned feed when signed releases are available.
    static let feedURL: URL? = nil
    static let unconfigured = "Barc updates are not configured yet. Builds and source are available at github.com/mcgri/Barc."

    struct Release: Decodable, Equatable {
        let version: String
        let url: URL?
        let notes: String?
        let downloadUrl: URL?

        init(version: String, url: URL? = nil, notes: String? = nil, downloadUrl: URL? = nil) {
            self.version = version
            self.url = url
            self.notes = notes
            self.downloadUrl = downloadUrl
        }

        /// The address to download, or nil when the feed only gave a page.
        ///
        /// A release page is not a package. Falling back to it meant the
        /// updater downloaded a few kilobytes of HTML, found it was not a
        /// disk image, and opened it -- which is how "update" ended in a
        /// browser window on GitHub. When there is nothing to download the
        /// answer is nil, and the caller opens the page deliberately instead
        /// of by accident.
        var updatePackageURL: URL? {
            if let downloadUrl, Self.isPackage(downloadUrl) { return downloadUrl }
            if let url, Self.isPackage(url) { return url }
            return nil
        }

        /// Whether an address names something that can be installed.
        static func isPackage(_ url: URL) -> Bool {
            ["dmg", "pkg", "zip"].contains(url.pathExtension.lowercased())
        }
    }

    enum Outcome: Equatable {
        /// This is the newest version the site knows about.
        case upToDate(current: String)
        /// The site has a newer one.
        ///
        /// The whole release, not a copy of some of it. This used to be three
        /// separate values and the one left out was `downloadUrl`, so by the
        /// time anything acted on the answer it no longer knew where the
        /// package was.
        case available(Release)
        /// No answer, or one that could not be read. The text says why.
        case unreachable(String)

        var release: Release? {
            if case .available(let release) = self { return release }
            return nil
        }

        /// The version the site is offering, for a status line.
        var offeredVersion: String? { release?.version }
    }

    static func decode(_ data: Data) throws -> Release {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.version.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "empty version"))
        }
        return release
    }

    /// Pure: compares what the site said with what is running.
    static func outcome(current: String, release: Release) -> Outcome {
        if AppVersion(release.version) > AppVersion(current) {
            return .available(release)
        }
        return .upToDate(current: current)
    }

    static func run(current: String = AppInfo.version, feed: URL? = feedURL) async -> Outcome {
        guard let feed else { return .unreachable(unconfigured) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(from: feed)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("The update server did not answer.")
            }
            guard http.statusCode == 200 else {
                return .unreachable("The update server answered \(http.statusCode).")
            }
            let release: Release
            do {
                release = try decode(data)
            } catch {
                return .unreachable("The update server answered with something that is not a release.")
            }
            return outcome(current: current, release: release)
        } catch {
            return .unreachable("Could not reach the update server. Check your connection and try again.")
        }
    }
}
