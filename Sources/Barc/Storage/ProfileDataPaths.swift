import Foundation

enum ProfileDataPaths {
    static func key(for identity: Space.Identity) -> String {
        switch identity {
        case .standard: return "standard"
        case .isolated(let id): return id.uuidString.lowercased()
        case .ephemeral(let id): return "private-" + id.uuidString.lowercased()
        }
    }

    static func directory(for identity: Space.Identity) -> URL {
        if identity == .standard { return AppPaths.supportDirectory }
        return AppPaths.supportDirectory.appending(path: "Profiles/" + key(for: identity), directoryHint: .isDirectory)
    }
}
