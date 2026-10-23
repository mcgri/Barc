// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit

/// Process entry point.
///
/// The app is built with SwiftPM rather than an Xcode project, so there is no
/// MainMenu.nib and no `NSPrincipalClass` bootstrap. Everything the nib would
/// normally do -- creating the shared application, installing the main menu and
/// opening the first window -- is done explicitly here and in `AppDelegate`.
@main
enum BarcApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
