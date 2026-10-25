// Added for Barc: synthetic Apple Passwords export fixtures only, 2026-10-25.
import Foundation
import Testing
@testable import Barc

@Suite("One-time macOS password import")
struct MacPasswordImporterTests {
    @Test("Apple CSV quoting, Unicode, BOM and multiline fields preserve credential values")
    func csvFormat() throws {
        let csv = "\u{feff}Title,URL,Username,Password,Notes,OTPAuth\r\n\"Site, one\",https://EXAMPLE.invalid:443/login,\"test,用户\",\"  sample\"\"secret\nsecond line  \",\"notes\nmore\",\r\n"
        let result = try MacPasswordImporter.parse(Data(csv.utf8))
        #expect(result.credentials.count == 1)
        let row = try #require(result.credentials.first)
        #expect(row.host == "example.invalid")
        #expect(row.username == "test,用户")
        #expect(row.password == "  sample\"secret\nsecond line  ")
        #expect(row.port == 0 && row.scheme == "https")
    }

    @Test("Only HTTP website passwords are imported; unsupported or empty records are counted")
    func skippedRecords() throws {
        let csv = "URL,Username,Password\nhttps://fixture.invalid:8443/,a,sample-one\nhttp://fixture.invalid:80/,b,sample-two\nhttps://fixture.invalid/,c,\nandroid://app,c,sample-three\nhttps://user:secret@fixture.invalid,c,sample-four\nnot-a-url,c,sample-five\n"
        let parsed = try MacPasswordImporter.parse(Data(csv.utf8))
        #expect(parsed.skipped == 4)
        #expect(parsed.credentials.count == 2)
        #expect(parsed.credentials.map(\.port) == [8443, 0])
        #expect(parsed.credentials.map(\.scheme) == ["https", "http"])
    }

    @Test("Malformed, incorrectly shaped, oversized and invalid UTF-8 files are rejected before writing")
    func invalidExports() {
        for text in ["URL,Username,Password\n\"unterminated,a,b", "URL,Username,Password\na,b", "URL,Username,Password\n\"a\"junk,b,c", "URL,URL,Password\na,b,c", "Title,Username\na,b", "URL,Username,Password\na\"bad,b,c"] {
            #expect(throws: MacPasswordImporter.Failure.self) { try MacPasswordImporter.parse(Data(text.utf8)) }
        }
        #expect(throws: MacPasswordImporter.Failure.self) { try MacPasswordImporter.parse(Data([0xff])) }
        #expect(throws: MacPasswordImporter.Failure.self) {
            try MacPasswordImporter.parse(Data(repeating: 0, count: MacPasswordImporter.maximumBytes + 1))
        }
    }

    @Test("Repeated imports preserve existing passwords and isolate destinations, schemes and ports")
    func scopedMerge() throws {
        let target = Space.Identity.makeIsolated(), other = Space.Identity.makeIsolated()
        let scope = ProfileDataPaths.key(for: target), otherScope = ProfileDataPaths.key(for: other)
        let parsed = try MacPasswordImporter.parse(Data("URL,Username,Password\nhttps://fixture.invalid,a,sample-new\nhttps://fixture.invalid,a,sample-duplicate\nhttp://fixture.invalid,a,sample-http\nhttps://fixture.invalid:8443,a,sample-port\nhttps://fixture.invalid,b,sample-b\n".utf8))
        let old = PasswordCredential(host: "fixture.invalid", username: "a", password: "sample-existing", storagePath: "/arc/source", scheme: "https")
        var entries = [WebsitePasswordVault.Entry(scope: scope, credential: old), .init(scope: otherScope, credential: old)]
        let summary = try MacPasswordImporter.merge(parsed, identity: target, into: &entries)
        #expect(summary == .init(imported: 3, existing: 2))
        #expect(entries.first?.credential == old)
        #expect(entries.filter { $0.scope == otherScope }.count == 1)
        let repeated = try MacPasswordImporter.merge(parsed, identity: target, into: &entries)
        #expect(repeated == .init(imported: 0, existing: 5))
        #expect(entries.count == 5)
        let before = entries
        #expect(throws: MacPasswordImporter.Failure.self) {
            try MacPasswordImporter.merge(parsed, identity: .makeEphemeral(), into: &entries)
        }
        #expect(entries == before)
    }

    @Test("Imported credentials survive encrypted reopening and a failed mutation preserves the vault")
    func encryptedBatch() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 7, count: 32)
        let access = WebsitePasswordVault.KeyAccess(read: { .success(key) }, create: { _ in .success(()) })
        let file = root.appending(path: "vault.barc")
        let vault = WebsitePasswordVault(file: file, access: access)
        let parsed = try MacPasswordImporter.parse(Data("URL,Username,Password\nhttps://fixture.invalid,a,fictional-import-value\n".utf8))
        try vault.mutate { entries in
            try MacPasswordImporter.merge(parsed, identity: .standard, into: &entries).imported > 0
        }
        let original = try Data(contentsOf: file)
        #expect(original.range(of: Data("fictional-import-value".utf8)) == nil)
        #expect(try WebsitePasswordVault(file: file, access: access).entries().count == 1)
        #expect(throws: MacPasswordImporter.Failure.self) {
            try vault.mutate { entries in
                entries.removeAll()
                throw MacPasswordImporter.Failure.invalidCSV
            }
        }
        #expect(try Data(contentsOf: file) == original)
    }
}
