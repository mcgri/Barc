// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import Foundation
import Security

/// One saved website login.
struct PasswordCredential: Equatable, Sendable, Identifiable {
    let host: String
    let username: String
    let password: String
    var storagePath: String? = nil
    var scheme: String? = nil
    var port: Int = 0

    var id: String { "\(host)\u{0000}\(username)\u{0000}\(storagePath ?? "")\u{0000}\(scheme ?? "")\u{0000}\(port)" }
}

/// Saves and reads website logins in the macOS login Keychain -- the system's
/// own store, iCloud-synced -- so Barc keeps no password database of its own.
/// Items are ordinary internet passwords, the same class Safari uses, so
/// they live beside the user's other saved logins and sync the same way.
///
/// Barc reads and writes its own items with no prompt; items another app saved
/// carry that app's access control, so reading them can raise the system's
/// "Allow" prompt -- which is the correct, user-visible boundary.
enum KeychainPasswordStore {
    /// New items are labelled so "Manage Passwords" can list the ones Barc saved
    /// without walking every internet password on the machine.
    static let label = "Barc"
    // Internet-password labels alone are not part of Keychain item uniqueness.
    // A dedicated path keeps Barc from updating or deleting another app's login.
    static let itemPath = "/__barc/website-login"

    static func port(for url: URL) -> Int {
        let port = url.port ?? 0
        return port == (url.scheme == "http" ? 80 : 443) ? 0 : port
    }

    static func label(for identity: Space.Identity) -> String {
        identity == .standard ? label : label + " · " + ProfileDataPaths.key(for: identity)
    }

    static func path(for identity: Space.Identity, sourceID: String? = nil) -> String {
        let base = identity == .standard ? itemPath : itemPath + "/" + ProfileDataPaths.key(for: identity)
        return sourceID.map { base + "/arc/" + ArcImportID.uuid($0).uuidString.lowercased() } ?? base
    }

    private static func query(host: String? = nil, account: String? = nil, identity: Space.Identity = .standard,
                              storagePath: String? = nil, scheme: String? = nil, port: Int? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecAttrLabel as String: label(for: identity)
        ]
        if let storagePath { query[kSecAttrPath as String] = storagePath }
        if let host { query[kSecAttrServer as String] = host }
        if let account { query[kSecAttrAccount as String] = account }
        // Earlier Barc builds saved default-profile items without a protocol.
        // Keep that query compatible; imported isolated profiles record it.
        if let scheme, identity != .standard { query[kSecAttrProtocol as String] = scheme == "http" ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS }
        if let port { query[kSecAttrPort as String] = port }
        return query
    }

    /// Saves a login, updating the password if the host and username already
    /// exist. Returns whether it was stored.
    @discardableResult
    static func save(host: String, username: String, password: String, identity: Space.Identity = .standard,
                     scheme: String = "https", port: Int = 0, storagePath: String? = nil, sourceID: String? = nil, overwrite: Bool = true) -> Bool {
        guard !identity.isPrivate else { return false }
        let itemQuery = query(host: host, account: username, identity: identity,
                              storagePath: storagePath ?? path(for: identity, sourceID: sourceID), scheme: scheme, port: port)
        if !overwrite {
            // Check attributes without reading a protected value. A denied read
            // must never look like absence and lead to overwriting an item.
            var existence = itemQuery
            existence[kSecReturnAttributes as String] = true
            existence[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(existence as CFDictionary, nil)
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { return false }
            var attributes = itemQuery
            attributes[kSecValueData as String] = Data(password.utf8)
            attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
            // Add directly, so an item created since the check is preserved.
            return add(attributes)
        }
        let data = Data(password.utf8)
        let update = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }

        var attributes = itemQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = label(for: identity)
        attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
        return add(attributes)
    }

    /// Every login stored for a host -- what autofill offers on that site.
    static func credentials(host: String, identity: Space.Identity = .standard, scheme: String? = nil, port: Int = 0) -> [PasswordCredential] {
        guard !identity.isPrivate else { return [] }
        return items(matching: query(host: host, identity: identity, scheme: scheme, port: port)).compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let password = password(in: item) else { return nil }
            return credential(host: host, account: account, password: password, item: item)
        }
    }

    /// Every login Barc has saved, for the Manage Passwords list.
    static func all(identity: Space.Identity = .standard) -> [PasswordCredential] {
        guard !identity.isPrivate else { return [] }
        return items(matching: query(identity: identity)).compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String,
                  let password = password(in: item) else { return nil }
            return credential(host: host, account: account, password: password, item: item)
        }.sorted { $0.host == $1.host ? $0.username < $1.username : $0.host < $1.host }
    }

    @discardableResult
    static func delete(host: String, username: String, identity: Space.Identity = .standard,
                       storagePath: String? = nil, scheme: String? = nil, port: Int = 0) -> Bool {
        SecItemDelete(query(host: host, account: username, identity: identity,
                            storagePath: storagePath ?? path(for: identity), scheme: scheme, port: port) as CFDictionary) == errSecSuccess
    }

    private static func credential(host: String, account: String, password: String, item: [String: Any]) -> PasswordCredential {
        let proto = item[kSecAttrProtocol as String] as? String
        return PasswordCredential(host: host, username: account, password: password,
                                  storagePath: item[kSecAttrPath as String] as? String,
                                  scheme: proto == (kSecAttrProtocolHTTP as String) ? "http" : "https",
                                  port: (item[kSecAttrPort as String] as? NSNumber)?.intValue ?? 0)
    }

    // MARK: - Helpers

    private static func add(_ attributes: [String: Any]) -> Bool {
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return true }
        // Local, ad-hoc builds cannot use Apple's synchronizable Keychain
        // without the signing entitlement. Keep the password in the login
        // Keychain instead, with the same native access control and namespace.
        guard status == errSecMissingEntitlement else { return false }
        var local = attributes
        local[kSecAttrSynchronizable as String] = false
        return SecItemAdd(local as CFDictionary, nil) == errSecSuccess
    }

    private static func items(matching query: [String: Any]) -> [[String: Any]] {
        var listing = query
        listing[kSecReturnAttributes as String] = true
        listing[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(listing as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        // The macOS login Keychain rejects returning password data together
        // with kSecMatchLimitAll. List attributes first, then read each exact
        // item individually through its normal native access control.
        return items.compactMap { attributes in
            var exact = query
            for key in [kSecAttrServer, kSecAttrAccount, kSecAttrPath, kSecAttrPort,
                        kSecAttrProtocol, kSecAttrSecurityDomain, kSecAttrAuthenticationType] {
                if let value = attributes[key as String] { exact[key as String] = value }
            }
            exact[kSecReturnData as String] = true
            exact[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: AnyObject?
            guard SecItemCopyMatching(exact as CFDictionary, &value) == errSecSuccess,
                  let data = value as? Data else { return nil }
            var item = attributes
            item[kSecValueData as String] = data
            return item
        }
    }

    private static func password(in item: [String: Any]) -> String? {
        guard let data = item[kSecValueData as String] as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Where Barc fills passwords from. The macOS Keychain is built in; every other
/// manager (1Password, Bitwarden, ...) plugs in as a browser extension, not as a
/// native provider -- there is no public API to read their vaults -- so
/// the alternative is simply "Others", which points the user at those.
enum PasswordProvider: String, CaseIterable, Sendable {
    case keychain
    case others

    var title: String {
        switch self {
        case .keychain: return "macOS Keychain"
        case .others: return "Others"
        }
    }
}

/// A password manager Barc can point the user to install, since it cannot read
/// the manager's vault itself -- clicking one opens its extension page in Barc.
struct PasswordManagerLink: Sendable {
    let name: String
    let url: URL

    static let common: [PasswordManagerLink] = [
        Self(name: "1Password", "https://1password.com/downloads/browser-extension/"),
        Self(name: "Bitwarden", "https://bitwarden.com/download/"),
        Self(name: "Dashlane", "https://www.dashlane.com/download"),
        Self(name: "Proton Pass", "https://proton.me/pass/download"),
        Self(name: "LastPass", "https://www.lastpass.com/misc/download")
    ]

    private init(name: String, _ url: String) {
        self.name = name
        self.url = URL(string: url)!
    }
}
