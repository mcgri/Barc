// Added for Barc: guided one-time import from Apple Passwords, 2026-10-25.
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacPasswordImportWindowController: NSWindowController {
    let identity: Space.Identity
    private let choose = NSButton(title: "Choose exported CSV…", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let open = NSButton(title: "Open Apple Passwords", target: nil, action: nil)
    private var task: Task<Void, Never>?

    init(identity: Space.Identity, spaceName: String) {
        self.identity = identity
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Import passwords from macOS"
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        func note(_ text: String, secondary: Bool = false) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: 13)
            if secondary { field.textColor = .secondaryLabelColor }
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        note("Import into: \(spaceName). Only this profile will receive the passwords.")
        note("1. Open Apple Passwords and unlock it.\n2. Choose File > Export All Passwords to File, or export selected accounts.\n3. Save the CSV, then choose it below to import into Barc.")
        open.bezelStyle = .rounded
        open.target = self; open.action = #selector(openPasswords)
        stack.addArrangedSubview(open)
        choose.bezelStyle = .rounded
        choose.target = self; choose.action = #selector(chooseExport)
        stack.addArrangedSubview(choose)
        note("On macOS Sonoma, export from Safari > Settings > Passwords instead.", secondary: true)
        note("Existing logins are kept. This is a one-time copy and does not sync with iCloud. Passkeys and verification codes are not imported.", secondary: true)
        note("The exported CSV contains readable passwords. Delete it after importing. Barc stores imported passwords in its encrypted vault.", secondary: true)
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24)
        ])
        window.contentView = container
    }

    required init?(coder: NSCoder) { fatalError("Created in code only") }

    @objc private func openPasswords() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    @objc private func chooseExport() {
        guard let window, task == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Apple Passwords export"
        panel.prompt = "Import passwords"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.startImport(url)
        }
    }

    private func startImport(_ url: URL) {
        choose.isEnabled = false
        open.isEnabled = false
        status.stringValue = "Importing passwords… Approve the Barc vault prompt if macOS asks."
        let identity = identity
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let parsed = try MacPasswordImporter.read(url)
                    guard !parsed.credentials.isEmpty else {
                        return Result<MacPasswordImporter.Summary, Error>.success(.init(skipped: parsed.skipped))
                    }
                    return .success(try KeychainPasswordStore.importMacPasswords(parsed, identity: identity))
                } catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.task = nil
            self.choose.isEnabled = true
            self.open.isEnabled = true
            switch result {
            case .success(let summary):
                self.status.stringValue = "Imported \(summary.imported). Already saved: \(summary.existing). Unsupported or empty entries skipped: \(summary.skipped). Delete the exported CSV when you’re done."
            case .failure(let error):
                // File paths, parser input and Keychain diagnostics may contain
                // private data. Keep the UI error independent of those values.
                self.status.stringValue = (error as? MacPasswordImporter.Failure)?.errorDescription
                    ?? "Couldn’t import this file. Choose a valid Apple Passwords CSV and approve vault access if prompted. Existing passwords were kept."
            }
        }
    }
}
