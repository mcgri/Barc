// Modified for Barc: scoped observation of native display accessibility changes, 2026-10-25.
import AppKit

/// Delivers workspace display changes on the UI thread and unregisters with
/// its owning control. Main-thread notifications are handled before returning.
@MainActor
final class DisplayOptionsObservation {
    private let center: NotificationCenter
    private nonisolated(unsafe) var token: NSObjectProtocol?

    init(_ onChange: @escaping @MainActor () -> Void) {
        center = NSWorkspace.shared.notificationCenter
        token = center.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                   object:nil,queue:.main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}
