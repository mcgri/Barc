import Foundation
import Testing
@testable import Barc

@Suite("Barc application identity")
struct BarcIdentityTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("The bundle has its own identity, icon and URL schemes")
    func bundleIdentity() throws {
        let data = try Data(contentsOf: Self.root.appending(path: "Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == "io.github.mcgri.Barc")
        for key in ["CFBundleExecutable", "CFBundleName", "CFBundleDisplayName", "CFBundleIconFile"] {
            #expect(plist[key] as? String == "Barc")
        }
        let types = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains("barc"))
        #expect(schemes.contains("barc-webapp"))
        #expect(!schemes.contains("kylmora"))
        #expect((plist["NSHumanReadableCopyright"] as? String)?.contains("© 2026 Kylmora") == true)
    }

    @Test("Attribution and license documents accompany the approved icon")
    func legalDocuments() throws {
        let notice = try String(contentsOf: Self.root.appending(path: "NOTICE"), encoding: .utf8)
        #expect(notice.contains("https://github.com/kylmora/kylmora"))
        #expect(notice.contains("© 2026 Kylmora"))
        let license = try String(contentsOf: Self.root.appending(path: "LICENSE"), encoding: .utf8)
        #expect(license.contains("Apache License"))
        #expect(license.contains("Version 2.0"))
        #expect(FileManager.default.fileExists(atPath: Self.root.appending(path: "Resources/Barc.icns").path))
    }

    @Test("Unconfigured updates do not fall back to Kylmora's feed")
    func noUpstreamFeed() async {
        #expect(UpdateCheck.feedURL == nil)
        #expect(await UpdateCheck.run() == .unreachable(UpdateCheck.unconfigured))
        #expect(AppInfo.website.absoluteString == "https://github.com/mcgri/Barc")
        #expect(SupportContact.issues.absoluteString == "https://github.com/mcgri/Barc/issues")
    }
}
