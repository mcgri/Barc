// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import Foundation

/// Defines how Barc manages HTTP and resource caching.
public enum CacheMode: String, CaseIterable, Codable, Sendable {
    /// Standard WebKit caching with disk persistence and volatile memory cache.
    case standard = "standard"
    /// Auxiliary memory caching with periodic WebKit disk-cache cleanup.
    case ramOnly = "ramOnly"
    /// Disable auxiliary caching and clear existing WebKit caches.
    case disabled = "disabled"

    public var title: String {
        switch self {
        case .standard:
            return "Standard"
        case .ramOnly:
            return "Reduced disk caching"
        case .disabled:
            return "Minimal caching"
        }
    }

    public var summary: String {
        switch self {
        case .standard:
            return "Uses a 4 MB auxiliary memory cache and disk caching; WebKit manages page caching."
        case .ramOnly:
            return "Disables auxiliary disk caching and periodically clears WebKit disk caches. WebKit controls its memory cache and may write data between cleanups."
        case .disabled:
            return "Disables auxiliary caching and clears WebKit caches when applied. WebKit may cache subsequent page loads."
        }
    }
}

/// Permitted memory capacity thresholds for RAM-only caching.
public enum RAMCacheCapacity: Int, CaseIterable, Codable, Sendable {
    case mb64 = 64
    case mb128 = 128
    case mb256 = 256
    case mb512 = 512
    case mb1024 = 1024

    public var title: String {
        switch self {
        case .mb64: return "64 MB"
        case .mb128: return "128 MB (Recommended)"
        case .mb256: return "256 MB"
        case .mb512: return "512 MB"
        case .mb1024: return "1 GB (High memory)"
        }
    }

    public var bytes: Int {
        rawValue * 1024 * 1024
    }
}
