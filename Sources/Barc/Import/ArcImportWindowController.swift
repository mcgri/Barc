import AppKit

@MainActor
final class ArcImportWindowController: NSWindowController, NSWindowDelegate {
    private let session: BrowserSession
    private let chooseButton = NSButton(title: "Choose Arc Folder…", target: nil, action: nil)
    private let importButton = NSButton(title: "Import Selected Data", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let reportButton = NSButton(title: "Show Report in Finder", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Imported Space", target: nil, action: nil)
    private let progressLabel = NSTextField(wrappingLabelWithString: "Choose Arc's folder to preview its profiles. Nothing is imported until you press Import Selected Data.")
    private let spinner = NSProgressIndicator()
    private let profileStack = NSStackView()
    private let results = NSTextView()
    private var profileBoxes: [String: NSButton] = [:]
    private let tabsBox = NSButton(checkboxWithTitle: "Tabs, folders, favourites and archives", target: nil, action: nil)
    private let historyBox = NSButton(checkboxWithTitle: "History and bookmarks", target: nil, action: nil)
    private let passwordBox = NSButton(checkboxWithTitle: "Saved passwords", target: nil, action: nil)
    private let cookieBox = NSButton(checkboxWithTitle: "Website cookies", target: nil, action: nil)
    private let storageBox = NSButton(checkboxWithTitle: "Website local storage", target: nil, action: nil)
    private let additionalBox = NSButton(checkboxWithTitle: "Addresses, search shortcuts and download history", target: nil, action: nil)
    private var categoryBoxes: [NSButton] { [tabsBox, historyBox, passwordBox, cookieBox, storageBox, additionalBox] }
    private var source: ArcSourceSnapshot?
    private var coordinator: ArcImportCoordinator?
    private var loadTask: Task<Void, Never>?
    private var captureTask: Task<ArcSourceSnapshot, Error>?
    private var importing = false
    private var loading = false
    private var firstImportedID: UUID?

    init(session: BrowserSession) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Import from Arc"
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 600)
        window.contentView = makeContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Arc import is created in code") }

    private func makeContent() -> NSView {
        let heading = NSTextField(labelWithString: "Bring Arc into Barc")
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Your Arc profiles stay separate. Existing Barc data is kept, and Arc is read from a private copy.")
        let limits = NSTextField(wrappingLabelWithString: "Some websites require a fresh sign-in. Website databases, tab-scoped data, passkeys and extensions remain in Arc. Payment cards are excluded.")
        limits.font = .systemFont(ofSize: 11)
        limits.textColor = .secondaryLabelColor
        chooseButton.target = self; chooseButton.action = #selector(chooseFolder)
        importButton.target = self; importButton.action = #selector(importSelected)
        closeButton.target = self; closeButton.action = #selector(closeTapped)
        reportButton.target = self; reportButton.action = #selector(showReport)
        openButton.target = self; openButton.action = #selector(openImported)
        for button in [chooseButton, importButton, closeButton, reportButton, openButton] { button.bezelStyle = .rounded }
        importButton.isEnabled = false
        reportButton.isHidden = true; openButton.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        profileStack.orientation = .vertical; profileStack.alignment = .leading; profileStack.spacing = 6
        for box in categoryBoxes { box.state = .on; box.target = self; box.action = #selector(selectionChanged) }
        let categories = NSStackView(views: categoryBoxes)
        categories.orientation = .vertical; categories.alignment = .leading; categories.spacing = 5
        let categoryTitle = NSTextField(labelWithString: "Data to import")
        categoryTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let progress = NSStackView(views: [spinner, progressLabel]); progress.alignment = .centerY
        results.isEditable = false; results.isRichText = false
        results.font = .systemFont(ofSize: 12)
        results.textContainerInset = NSSize(width: 8, height: 8)
        results.isVerticallyResizable = true; results.isHorizontallyResizable = false
        results.autoresizingMask = [.width]
        results.textContainer?.widthTracksTextView = true
        results.frame = NSRect(x: 0, y: 0, width: 600, height: 180)
        let scroll = NSScrollView()
        scroll.documentView = results; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let actions = NSStackView(views: [reportButton, openButton, NSView(), closeButton, importButton])
        actions.distribution = .fill; actions.spacing = 8
        let stack = NSStackView(views: [heading, intro, chooseButton, profileStack, categoryTitle, categories, limits, scroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        let page = NSScrollView()
        page.hasVerticalScroller = true; page.drawsBackground = false
        page.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack); page.documentView = document
        container.addSubview(page); container.addSubview(progress); container.addSubview(actions)
        progress.translatesAutoresizingMaskIntoConstraints = false; actions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor), page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor), page.bottomAnchor.constraint(equalTo: progress.topAnchor, constant: -12),
            progress.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22), progress.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            progress.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.leadingAnchor.constraint(equalTo: progress.leadingAnchor), actions.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            document.widthAnchor.constraint(equalTo: page.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            limits.widthAnchor.constraint(equalTo: intro.widthAnchor), scroll.widthAnchor.constraint(equalTo: intro.widthAnchor)
        ])
        return container
    }

    private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }

    @objc private func chooseFolder() {
        guard !importing else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose Arc's Folder"
        picker.message = "Choose the Arc folder in Library/Application Support, containing User Data and StorableSidebar.json."
        picker.directoryURL = ArcSourceSnapshotter.defaultFolder
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let selected = picker.url else { return }
        load(selected)
    }

    func load(_ selected: URL) {
        guard !importing else { return }
        coordinator?.clearSensitiveState(); coordinator = nil
        loadTask?.cancel(); captureTask?.cancel()
        source?.remove(); source = nil
        for view in profileStack.arrangedSubviews { profileStack.removeArrangedSubview(view); view.removeFromSuperview() }
        profileBoxes.removeAll()
        results.string = ""; reportButton.isHidden = true; openButton.isHidden = true
        firstImportedID = nil
        loading = true; updateControls(); spinner.startAnimation(nil)
        progressLabel.stringValue = "Making a private snapshot of Arc and reading its profiles…"
        let access = selected.startAccessingSecurityScopedResource()
        let task = Task.detached { try ArcSourceSnapshotter.capture(selected) }
        captureTask = task
        loadTask = Task { [weak self] in
            var pending: ArcSourceSnapshot?
            defer { pending?.remove() }
            defer { if access { selected.stopAccessingSecurityScopedResource() } }
            do {
                let snapshot = try await task.value
                pending = snapshot
                guard let self, !Task.isCancelled else { snapshot.remove(); return }
                let inventory = try await Task.detached { try ArcProfileInventory.read(snapshot) }.value
                if Task.isCancelled { snapshot.remove(); return }
                self.source?.remove(); self.source = snapshot
                pending = nil
                self.populate(snapshot, inventory: inventory)
            } catch {
                self?.progressLabel.stringValue = error.localizedDescription
            }
            self?.loading = false; self?.spinner.stopAnimation(nil); self?.updateControls()
        }
    }

    private func populate(_ snapshot: ArcSourceSnapshot, inventory: [ArcProfileInventory]) {
        for view in profileStack.arrangedSubviews { profileStack.removeArrangedSubview(view); view.removeFromSuperview() }
        profileBoxes.removeAll()
        let spaces = ArcSpaceBuilder.build(snapshot, options: ArcImportOptions(profileIDs: Set(snapshot.profiles.map(\.folder))))
        for profile in snapshot.profiles {
            let tabs = spaces.filter { $0.profile == profile.folder }.reduce(0) { $0 + $1.snapshot.tabs.count }
            let counts = inventory.first { $0.profile.folder == profile.folder }
            let box = NSButton(checkboxWithTitle: "\(profile.name) · \(tabs) \(tabs == 1 ? "tab" : "tabs") · \(counts?.passwords ?? 0) saved passwords · \(counts?.history ?? 0) history visits", target: self, action: #selector(selectionChanged))
            box.state = .on; box.identifier = NSUserInterfaceItemIdentifier(profile.folder)
            profileStack.addArrangedSubview(box); profileBoxes[profile.folder] = box
        }
        let unassigned = spaces.first { $0.profile == nil }?.snapshot.archivedTabs?.count ?? 0
        progressLabel.stringValue = "Found \(snapshot.profiles.count) profiles. \(unassigned > 0 ? "\(unassigned) archived web tabs from deleted Spaces will be kept in an Unassigned Arc archive Space." : "Choose the profiles and data you want.")"
        results.string = ""
        importButton.title = "Import Selected Data"
    }

    @objc private func selectionChanged() { updateControls() }
    private func updateControls() {
        let busy = loading || importing
        chooseButton.isEnabled = !busy
        closeButton.isEnabled = !importing
        categoryBoxes.forEach { $0.isEnabled = !busy }
        profileBoxes.values.forEach { $0.isEnabled = !busy }
        importButton.isEnabled = !busy && source != nil && profileBoxes.values.contains { $0.state == .on }
            && categoryBoxes.contains { $0.state == .on }
        window?.standardWindowButton(.closeButton)?.isEnabled = !importing
    }

    @objc private func importSelected() {
        guard !importing, let source else { return }
        let selected = Set(profileBoxes.filter { $0.value.state == .on }.map(\.key))
        var options = ArcImportOptions(profileIDs: selected)
        options.sidebar = tabsBox.state == .on; options.history = historyBox.state == .on; options.bookmarks = options.history
        options.passwords = passwordBox.state == .on; options.cookies = cookieBox.state == .on
        options.localStorage = storageBox.state == .on; options.supplementary = additionalBox.state == .on
        let coordinator = self.coordinator ?? ArcImportCoordinator(session: session)
        self.coordinator = coordinator
        coordinator.progress = { [weak self] in self?.progressLabel.stringValue = $0 }
        let built = ArcSpaceBuilder.build(source, options: options)
        firstImportedID = (built.first { $0.sourceSpaceID == source.sidebar.activeSpaceID } ?? built.first { $0.profile != nil })?.snapshot.id
        importing = true; updateControls(); spinner.startAnimation(nil)
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await coordinator.run(source, options: options)
                self.results.string = Self.text(report)
                self.results.enclosingScrollView?.scrollToVisible(self.results.enclosingScrollView?.bounds ?? .zero)
                self.progressLabel.stringValue = report.summary
                self.openButton.isHidden = false
                self.importButton.title = "Import Again"
            } catch { self.progressLabel.stringValue = error.localizedDescription }
            self.reportButton.isHidden = coordinator.reportURL == nil
            self.importing = false; self.spinner.stopAnimation(nil); self.updateControls()
        }
    }

    static func text(_ report: ArcImportReport) -> String {
        var lines: [String] = [report.summary, ""]
        for profile in report.profiles {
            lines.append(profile.name)
            for name in profile.counts.keys.sorted() {
                guard let count = profile.counts[name] else { continue }
                lines.append("  \(name): \(count.imported) imported, \(count.existing) already present, \(count.skipped) skipped, \(count.failed) unavailable; \(count.verified) verified")
                for reason in (count.skipReasons ?? [:]).keys.sorted() {
                    lines.append("    \(reason): \(count.skipReasons?[reason] ?? 0)")
                }
                for reason in (count.failureReasons ?? [:]).keys.sorted() {
                    lines.append("    \(reason): \(count.failureReasons?[reason] ?? 0)")
                }
            }
            lines += profile.notes.map { "  " + $0 }
            lines.append("")
        }
        lines += report.notes
        return lines.joined(separator: "\n")
    }

    @objc private func closeTapped() { close() }
    @objc private func showReport() { if let url = coordinator?.reportURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc private func openImported() {
        if let id = firstImportedID, let space = session.spaces.first(where: { $0.id == id }) { session.selectSpace(space) }
        close()
        NSApp.windows.first { $0.windowController is BrowserWindowController }?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !importing }
    func windowWillClose(_ notification: Notification) {
        coordinator?.clearSensitiveState(); coordinator = nil
        loadTask?.cancel(); captureTask?.cancel(); source?.remove(); source = nil
        updateControls()
    }
}
