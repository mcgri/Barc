import ObjectiveC
import WebKit

/// WebKit's own fingerprinting protection, the one Safari turns on for
/// Advanced Fingerprinting Protection.
///
/// It adds noise to canvas and audio readouts and reports the screen's full
/// size as its available size, as Barc's anti-fingerprinting script does,
/// but inside WebKit: the page's functions stay WebKit's own. Bot checks
/// such as the ones on GoDaddy's sign-in look for functions a script has
/// replaced, and refused Barc for the script while accepting this.
///
/// The switch is private: one bit of `WKWebpagePreferences`'
/// `_networkConnectionIntegrityPolicy`, WebKit's advanced privacy
/// protections. Where a macOS release drops or moves it, `isAvailable` is
/// false and Barc falls back to the script.
@MainActor
enum NativeFingerprintingProtection {
    /// The fingerprinting-protections bit. Found by setting each bit in turn
    /// on macOS 27: this is the one that changes canvas, audio and screen
    /// readouts, and no other bit changes any of them.
    static let bit: UInt = 1 << 6

    private static let getter = Selector(("_networkConnectionIntegrityPolicy"))
    private static let setter = Selector(("_setNetworkConnectionIntegrityPolicy:"))

    private typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
    private typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void

    /// Whether this WebKit has the switch and keeps what is set on it.
    static let isAvailable: Bool = {
        let preferences = WKWebpagePreferences()
        guard preferences.responds(to: getter), preferences.responds(to: setter) else { return false }
        write(bit, to: preferences)
        return read(preferences) == bit
    }()

    /// Turns the protection on or off for the pages `preferences` load,
    /// leaving WebKit's other privacy protections as they were. Returns
    /// false, and changes nothing, where the switch is not available.
    @discardableResult
    static func set(_ enabled: Bool, in preferences: WKWebpagePreferences) -> Bool {
        guard isAvailable else { return false }
        let current = read(preferences)
        let next = enabled ? current | bit : current & ~bit
        if next != current { write(next, to: preferences) }
        return true
    }

    static func isEnabled(in preferences: WKWebpagePreferences) -> Bool {
        isAvailable && read(preferences) & bit != 0
    }

    /// The whole policy, every protection's bit. Typed calls, not key-value
    /// coding: the setter's name has no key-value spelling, and setting it
    /// by key throws.
    static func read(_ preferences: WKWebpagePreferences) -> UInt {
        guard let imp = class_getMethodImplementation(object_getClass(preferences), getter) else { return 0 }
        return unsafeBitCast(imp, to: Getter.self)(preferences, getter)
    }

    static func write(_ value: UInt, to preferences: WKWebpagePreferences) {
        guard let imp = class_getMethodImplementation(object_getClass(preferences), setter) else { return }
        unsafeBitCast(imp, to: Setter.self)(preferences, setter, value)
    }
}
