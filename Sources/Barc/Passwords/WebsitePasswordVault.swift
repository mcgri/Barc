import CryptoKit
import Darwin
import Foundation
import Security

/// All website credentials share one encryption key, protected by one macOS
/// Keychain item. The encrypted file is reread under a process-shared lock on
/// every operation; only the key is cached after a successful system approval.
final class WebsitePasswordVault: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let scope: String
        var credential: PasswordCredential
    }
    enum Failure: Error, Equatable {
        case keychain(OSStatus), missingKey, invalidKey, invalidVault, fileAccess
    }
    struct KeyAccess: Sendable {
        var read: @Sendable () -> Result<Data?, Failure>
        var create: @Sendable (Data) -> Result<Void, Failure>

        static func keychain(service: String, account: String = "website-password-vault-v1") -> Self {
            @Sendable func query() -> [String: Any] {
                [kSecClass as String: kSecClassGenericPassword,
                 kSecAttrService as String: service, kSecAttrAccount as String: account,
                 kSecAttrSynchronizable as String: false]
            }
            return Self(read: {
                var request = query()
                request[kSecReturnData as String] = true
                request[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: AnyObject?
                let status = SecItemCopyMatching(request as CFDictionary, &result)
                if status == errSecItemNotFound { return .success(nil) }
                guard status == errSecSuccess, let data = result as? Data else { return .failure(.keychain(status)) }
                return .success(data)
            }, create: { data in
                var request = query()
                request[kSecAttrLabel as String] = "Barc saved-password vault"
                request[kSecValueData as String] = data
                let status = SecItemAdd(request as CFDictionary, nil)
                return status == errSecSuccess ? .success(()) : .failure(.keychain(status))
            })
        }
    }

    private static let header = Data("BARCPWV1".utf8)
    private let file: URL
    private let access: KeyAccess
    private let lock = NSRecursiveLock()
    private var cachedKey: SymmetricKey?
    private var keyFailure: Failure?

    init(file: URL, access: KeyAccess) { self.file = file; self.access = access }

    /// A deliberate retry may ask again after denial. Successful access stays
    /// cached for this process, including across all six profile imports.
    func retryAccess() {
        lock.lock(); defer { lock.unlock() }
        keyFailure = nil
    }

    func entries() throws -> [Entry] {
        try transaction { try readEntries() }
    }

    @discardableResult
    func mutate(_ change: (inout [Entry]) -> Bool) throws -> Bool {
        try transaction {
            var entries = try readEntries()
            guard change(&entries) else { return false }
            let key = try encryptionKey(create: !FileManager.default.fileExists(atPath: file.path))
            let plain = try JSONEncoder().encode(entries)
            let box = try AES.GCM.seal(plain, using: key, authenticating: Self.header)
            guard let combined = box.combined else { throw Failure.invalidVault }
            try (Self.header + combined).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        }
    }

    private func readEntries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.starts(with: Self.header) else { throw Failure.invalidVault }
        let key = try encryptionKey(create: false)
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.header.count))
            let plain = try AES.GCM.open(box, using: key, authenticating: Self.header)
            return try JSONDecoder().decode([Entry].self, from: plain)
        } catch { throw Failure.invalidVault }
    }

    private func encryptionKey(create: Bool) throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        if let keyFailure { throw keyFailure }
        do {
            if let data = try access.read().get() {
                guard data.count == 32 else { throw Failure.invalidKey }
                let key = SymmetricKey(data: data)
                cachedKey = key
                return key
            }
            guard create else { throw Failure.missingKey }
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            try access.create(data).get()
            cachedKey = key
            return key
        } catch {
            let failure = error as? Failure ?? .fileAccess
            keyFailure = failure
            throw failure
        }
    }

    private func transaction<T>(_ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.fileAccess }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Failure.fileAccess }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
}
