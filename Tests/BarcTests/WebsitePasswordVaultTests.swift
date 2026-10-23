import Foundation
import Security
import Testing
@testable import Barc

private final class VaultFixtureKey: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private(set) var reads = 0
    private(set) var creates = 0
    var denied = false
    var access: WebsitePasswordVault.KeyAccess {
        .init(read: {
            self.lock.lock(); defer { self.lock.unlock() }
            self.reads += 1
            return self.denied ? .failure(.keychain(errSecAuthFailed)) : .success(self.value)
        }, create: { data in
            self.lock.lock(); defer { self.lock.unlock() }
            self.creates += 1; self.value = data; return .success(())
        })
    }
}

@Suite("One-approval website password vault")
struct WebsitePasswordVaultTests {
    private func entry(_ index: Int, scope: String = "personal") -> WebsitePasswordVault.Entry {
        .init(scope: scope, credential: .init(host: "fixture.invalid", username: index == 0 ? "" : "user-\(index)",
            password: "fictional-password-\(index)", storagePath: "/fixture/\(index)", scheme: "https", port: index == 1 ? 8443 : 0))
    }

    @Test("148 credentials need one key lookup, survive reopening and keep their scopes")
    func singleLookup() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = VaultFixtureKey()
        let file = root.appending(path: "passwords/vault.barc")
        let first = WebsitePasswordVault(file: file, access: key.access)
        #expect(try first.entries().isEmpty)
        #expect(key.reads == 0)
        let expected = (0..<148).map { entry($0, scope: "profile-\($0 % 6)") }
        for row in expected { try first.mutate { $0.append(row); return true } }
        #expect(key.reads == 1)
        #expect(key.creates == 1)
        #expect(try first.entries() == expected)
        let raw = try Data(contentsOf: file)
        #expect(raw.range(of: Data("fictional-password".utf8)) == nil)
        #expect(raw.range(of: Data("fixture.invalid".utf8)) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reopened = WebsitePasswordVault(file: file, access: key.access)
        for _ in 0..<148 { #expect(try reopened.entries() == expected) }
        #expect(key.reads == 2)
        #expect(key.creates == 1)
        #expect(try reopened.entries().filter { $0.scope == "profile-0" }.count == 25)
    }

    @Test("Tampering and denied key access never replace existing encrypted credentials")
    func failuresPreserveData() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = VaultFixtureKey()
        let file = root.appending(path: "vault.barc")
        let first = WebsitePasswordVault(file: file, access: key.access)
        try first.mutate { $0.append(entry(0)); return true }
        let original = try Data(contentsOf: file)
        key.denied = true
        let denied = WebsitePasswordVault(file: file, access: key.access)
        for _ in 0..<148 {
            #expect(throws: WebsitePasswordVault.Failure.self) { try denied.entries() }
        }
        #expect(key.reads == 2)
        #expect(throws: WebsitePasswordVault.Failure.self) { try denied.mutate { $0.removeAll(); return true } }
        #expect(try Data(contentsOf: file) == original)
        key.denied = false
        denied.retryAccess()
        #expect(try denied.entries() == [entry(0)])
        var damaged = original
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: file)
        #expect(throws: WebsitePasswordVault.Failure.self) { try denied.mutate { $0.removeAll(); return true } }
        #expect(try Data(contentsOf: file) == damaged)
        let missingKey = WebsitePasswordVault(file: file, access: VaultFixtureKey().access)
        #expect(throws: WebsitePasswordVault.Failure.self) { try missingKey.mutate { $0.removeAll(); return true } }
        #expect(try Data(contentsOf: file) == damaged)
    }

    @Test("Two vault instances merge fresh encrypted data instead of overwriting each other's changes")
    func independentInstances() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = VaultFixtureKey()
        let file = root.appending(path: "vault.barc")
        let first = WebsitePasswordVault(file: file, access: key.access)
        let second = WebsitePasswordVault(file: file, access: key.access)
        try first.mutate { $0.append(entry(1)); return true }
        #expect(try second.entries() == [entry(1)])
        try first.mutate { $0.append(entry(2)); return true }
        try second.mutate { $0.append(entry(3)); return true }
        #expect(try first.entries() == [entry(1), entry(2), entry(3)])
    }

    @Test("Legacy conversion preserves newer values, scope boundaries and repeated imports")
    func legacyConversion() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = VaultFixtureKey()
        let vault = WebsitePasswordVault(file: root.appending(path: "vault.barc"), access: key.access)
        var newer = entry(1)
        newer.credential = .init(host: newer.credential.host, username: newer.credential.username,
            password: "fictional-newer", storagePath: newer.credential.storagePath, scheme: "https", port: 8443)
        try vault.mutate { $0.append(newer); return true }
        try vault.retainLegacy([entry(1).credential, entry(2).credential], scope: "personal")
        try vault.retainLegacy([entry(1).credential], scope: "work")
        try vault.retainLegacy([entry(1).credential, entry(2).credential], scope: "personal")
        let saved = try vault.entries()
        #expect(saved.count == 3)
        #expect(saved.first(where: { $0.scope == "personal" && $0.credential.username == "user-1" })?.credential.password == "fictional-newer")
        #expect(saved.first(where: { $0.scope == "work" })?.credential.password == "fictional-password-1")
        #expect(key.reads == 1)
    }

    @Test("One real Keychain key unlocks all 148 synthetic credentials",
          .enabled(if: ProcessInfo.processInfo.environment["BARC_TEST_SYNTHETIC_KEYCHAIN"] == "1"))
    func nativeSingleItem() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = "io.github.mcgri.Barc.fixture-vault-" + UUID().uuidString
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service] as CFDictionary) }
        let file = root.appending(path: "vault.barc")
        let first = WebsitePasswordVault(file: file, access: .keychain(service: service))
        let expected = (0..<148).map { entry($0, scope: "profile-\($0 % 6)") }
        try first.mutate { $0 = expected; return true }
        let reopened = WebsitePasswordVault(file: file, access: .keychain(service: service))
        #expect(try reopened.entries() == expected)
        var result: AnyObject?
        #expect(SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll] as CFDictionary, &result) == errSecSuccess)
        #expect((result as? [[String: Any]])?.count == 1)
    }
}
