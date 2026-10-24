// Modified for Barc: sidebar address editing and themed launcher presentation, 2026-10-24.
import AppKit

/// Sizes shared by the centered launcher and the compact sidebar URL popup.
enum CommandBarMetrics {
    static let newTabRecentLimit = 4
    /// Empty action space retained by Arc's compact URL suggestions.
    static let compactResultActionSpace: CGFloat = 51
    static let addressPanelWidth: CGFloat = 350
    static let addressFieldHeight: CGFloat = 44
    /// Wide enough for a long URL and its title, narrow enough that the panel
    /// still reads as a floating object rather than a sheet.
    static let panelWidth: CGFloat = 640
    /// Never let the panel touch the window edge, however narrow the window.
    static let minimumSideGap: CGFloat = 48
    /// Keep the centered panel clear of both vertical edges.
    static let verticalGap: CGFloat = 72
    /// Breathing room kept below the panel when the results list is at its
    /// tallest, so a full list never runs into the bottom of the window.
    static let bottomGap: CGFloat = 24

    static let cornerRadius: CGFloat = 14
    static let shadowRadius: CGFloat = 30
    static let shadowOpacity: Float = 0.28
    static let shadowOffset = CGSize(width: 0, height: -8)

    /// The query row: one line of 19pt text with generous padding on all sides.
    static let fieldHeight: CGFloat = 56
    static let fieldInset: CGFloat = 20
    static let queryFontSize: CGFloat = 19

    static let rowHeight: CGFloat = 40
    static let rowInset: CGFloat = 14
    static let rowCornerRadius: CGFloat = 8
    static let rowIconSide: CGFloat = 16
    static let rowSpacing: CGFloat = 2
    static let rowLabelSpacing: CGFloat = 8
    static let subtitleFontSize: CGFloat = 11
    /// Padding around the whole result list, inside the panel.
    static let listInset: CGFloat = 6
    static let splitRowHeight: CGFloat = 46
    static let splitRowSpacing: CGFloat = 4
    static let dividerHeight: CGFloat = 1

    /// Long enough that holding a key down does not queue a query per
    /// keystroke, short enough to still feel like search-as-you-type. Same
    /// reasoning, and the same figure, as `FindController.typingDelay`.
    static let typingDelay = Duration.milliseconds(90)
}

/// One URL editor with two placements: an anchored sidebar popup for an existing
/// page, and a centered launcher for New Tab. Both own focus until dismissed,
/// discard abandoned edits, and receive suggestions without owning the session.
@MainActor
final class CommandBar: NSView, NSTextFieldDelegate {
    /// Supplies rows for a query. Async because history is a database read;
    /// the bar debounces, cancels superseded queries and discards answers that
    /// arrive after the text has moved on.
    /// The engine a bare query searches with: the private one in a private
    /// space. Nil falls back to the ordinary engine.
    var searchEngineProvider: (() -> SearchEngine)?

    var resultsProvider: (@MainActor (String) async -> [CommandResult])?
    var resultImageProvider: ((CommandResult) -> NSImage?)?
    var onClose: (() -> Void)?
    var onCancel: (() -> Void)?
    var selectionColor: NSColor = .selectedContentBackgroundColor {
        didSet {
            for case let row as CommandRowView in rowsStack.arrangedSubviews { row.selectionColor = selectionColor }
        }
    }

    var textSelectionColor: NSColor = .selectedTextBackgroundColor {
        didSet { applyTextSelection() }
    }
    private weak var themedEditor: NSTextView?
    private var originalSelectionAttributes: [NSAttributedString.Key: Any]?

    /// Performs a chosen row, or the address the user typed. The bar resolves
    /// text into a `URL` itself so that the caller has one case to handle
    /// rather than two, but it never navigates: it has no session to navigate.
    var onRun: ((CommandAction, Bool) -> Void)?

    private let shadowHost = NSView()
    private let panel = CommandPanelView()
    private let fieldRow = NSView()
    private let field = NSTextField()
    private let addressIcon = NSImageView()
    private let divider = NSBox()
    private let rowsStack = CommandResultsView()
    private let resultsContainer = NSStackView()
    private var centeredConstraints: [NSLayoutConstraint] = []
    private var addressConstraints: [NSLayoutConstraint] = []
    private var preferredWidth: NSLayoutConstraint!
    private var addressLeading: NSLayoutConstraint!
    private var addressTop: NSLayoutConstraint!
    private var fieldHeight: NSLayoutConstraint!
    private var fieldLeading: NSLayoutConstraint!
    private var addressIconLeading: NSLayoutConstraint!
    private var listWidths: [NSLayoutConstraint] = []
    private var dividerHeight: NSLayoutConstraint!
    private weak var addressAnchor: NSView?
    private weak var splitAnchor: NSView?
    private weak var centerHost: NSView?
    private var initialAddressResults: [CommandResult] = []
    private var initialSplitResults: [CommandResult] = []
    private var initialNewTabResults: [CommandResult] = []
    private var initialLocationResults: [CommandResult] = []
    private var typedQuery = ""
    private var hasEditedQuery = false
    private var usesLauncherRows = false
    private(set) var isAddressMode = false
    private(set) var isSplitMode = false
    private(set) var isLocationMode = false

    private var queryTask: Task<Void, Never>?
    /// Whatever held focus when the bar opened -- in practice the page. Weak
    /// because a tab can close while the bar is open, and the bar has no
    /// business keeping that view alive.
    private weak var previousResponder: NSResponder?

    /// Everything the ranker returned, in order.
    private(set) var results: [CommandResult] = []
    /// The rows actually built, which is `results` clipped to what fits the
    /// window. See `maximumVisibleRows(inHeight:)`.
    private(set) var visibleResults: [CommandResult] = []
    /// nil means the query line itself is selected: Return navigates to what
    /// was typed rather than to a row.
    private(set) var selectedIndex: Int?

    /// Whether this opening was triggered to create a new tab (e.g. Cmd-T).
    private(set) var isNewTabMode = false

    var queryText: String { field.stringValue }

    var isOpen: Bool { !isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        buildPanel()
        applyShadowColor()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command Bar")
    }

    required init?(coder: NSCoder) {
        fatalError("CommandBar is created in code only")
    }

    // MARK: - Construction

    private func buildPanel() {
        shadowHost.wantsLayer = true
        shadowHost.layer?.cornerCurve = .continuous
        shadowHost.layer?.cornerRadius = CommandBarMetrics.cornerRadius
        shadowHost.layer?.shadowRadius = CommandBarMetrics.shadowRadius
        shadowHost.layer?.shadowOpacity = CommandBarMetrics.shadowOpacity
        shadowHost.layer?.shadowOffset = CommandBarMetrics.shadowOffset
        shadowHost.translatesAutoresizingMaskIntoConstraints = false

        // The panel clips to the rounded corners, and a layer that
        // masks its bounds cannot also cast a shadow -- hence the extra host.
        panel.wantsLayer = true
        panel.layer?.cornerCurve = .continuous
        panel.layer?.cornerRadius = CommandBarMetrics.cornerRadius
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 0.5
        panel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(shadowHost)
        shadowHost.addSubview(panel)

        buildFieldRow()
        buildResultsContainer()

        let content = NSStackView(views: [fieldRow, resultsContainer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)

        preferredWidth = shadowHost.widthAnchor.constraint(
            equalToConstant: CommandBarMetrics.panelWidth
        )
        // Loses to the window, wins over everything else: a narrow window
        // shrinks the panel instead of pushing it off screen.
        preferredWidth.priority = .init(999)

        centeredConstraints = [
            shadowHost.centerXAnchor.constraint(equalTo: centerXAnchor),
            shadowHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            shadowHost.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor,
                constant: -2 * CommandBarMetrics.minimumSideGap
            )
        ]
        addressLeading = shadowHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        addressTop = shadowHost.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        addressConstraints = [addressLeading, addressTop,
            shadowHost.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8)]
        NSLayoutConstraint.activate(centeredConstraints)
        NSLayoutConstraint.activate([
            preferredWidth,

            panel.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            panel.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),

            content.topAnchor.constraint(equalTo: panel.topAnchor),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            // Both rows span the panel. Activated here because a constraint
            // between two views needs them to share an ancestor first.
            fieldRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            resultsContainer.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    private func buildFieldRow() {
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: CommandBarMetrics.queryFontSize)
        field.textColor = Style.Colors.primaryText
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.placeholderString = "Search, enter address, or type a command"
        field.delegate = self
        field.setAccessibilityLabel("Search, enter address, or type a command")
        field.translatesAutoresizingMaskIntoConstraints = false

        fieldRow.translatesAutoresizingMaskIntoConstraints = false
        fieldRow.addSubview(field)
        addressIcon.translatesAutoresizingMaskIntoConstraints = false
        addressIcon.imageScaling = .scaleProportionallyDown
        addressIcon.setAccessibilityElement(false)
        addressIcon.isHidden = true
        fieldRow.addSubview(addressIcon)
        fieldHeight = fieldRow.heightAnchor.constraint(equalToConstant: CommandBarMetrics.fieldHeight)
        fieldLeading = field.leadingAnchor.constraint(equalTo: fieldRow.leadingAnchor, constant: CommandBarMetrics.fieldInset)
        addressIconLeading = addressIcon.leadingAnchor.constraint(equalTo: fieldRow.leadingAnchor, constant: 16)

        NSLayoutConstraint.activate([
            fieldHeight, fieldLeading,
            addressIconLeading,
            addressIcon.centerYAnchor.constraint(equalTo: fieldRow.centerYAnchor),
            addressIcon.widthAnchor.constraint(equalToConstant: 16),
            addressIcon.heightAnchor.constraint(equalToConstant: 16),
            field.trailingAnchor.constraint(
                equalTo: fieldRow.trailingAnchor,
                constant: -CommandBarMetrics.fieldInset
            ),
            field.centerYAnchor.constraint(equalTo: fieldRow.centerYAnchor)
        ])
    }

    private func buildResultsContainer() {
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.onSelect = { [weak self] index in
            self?.select(index)
            self?.previewSelection()
        }
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = CommandBarMetrics.rowSpacing
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        resultsContainer.orientation = .vertical
        resultsContainer.alignment = .leading
        resultsContainer.spacing = CommandBarMetrics.listInset
        resultsContainer.edgeInsets = NSEdgeInsets(
            top: 0,
            left: CommandBarMetrics.listInset,
            bottom: CommandBarMetrics.listInset,
            right: CommandBarMetrics.listInset
        )
        resultsContainer.setViews([divider, rowsStack], in: .top)
        resultsContainer.translatesAutoresizingMaskIntoConstraints = false
        // Hidden, and therefore collapsed by the enclosing stack: with nothing
        // to show, the panel is exactly one row tall.
        resultsContainer.isHidden = true

        let inset = -2 * CommandBarMetrics.listInset
        dividerHeight = divider.heightAnchor.constraint(equalToConstant: CommandBarMetrics.dividerHeight)
        listWidths = [
            divider.widthAnchor.constraint(equalTo: resultsContainer.widthAnchor, constant: inset),
            rowsStack.widthAnchor.constraint(equalTo: resultsContainer.widthAnchor, constant: inset)
        ]
        NSLayoutConstraint.activate([dividerHeight] + listWidths)
    }

    // MARK: - Installing

    /// Adds the bar over `host`, filling it. Called once; the bar stays hidden
    /// until it is opened.
    ///
    /// It fills the host rather than sitting at the top of it because the empty
    /// area *is* the dismiss target: a click anywhere outside the panel closes
    /// the bar, and a view cannot receive a click it does not cover.
    func install(in host: NSView, centeredIn centerHost: NSView? = nil) {
        self.centerHost = centerHost ?? self
        host.addSubview(self)
        if let centerHost {
            NSLayoutConstraint.deactivate(centeredConstraints)
            centeredConstraints = [
                shadowHost.centerXAnchor.constraint(equalTo: centerHost.centerXAnchor),
                shadowHost.centerYAnchor.constraint(equalTo: centerHost.centerYAnchor),
                shadowHost.widthAnchor.constraint(lessThanOrEqualTo: centerHost.widthAnchor,
                                                  constant: -2 * CommandBarMetrics.minimumSideGap)
            ]
            NSLayoutConstraint.activate(centeredConstraints)
        }
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    // MARK: - Opening and closing

    /// Opens the bar with `text` selected, so the first keystroke replaces it.
    func open(text: String = "", openInNewTab: Bool = false) {
        configurePresentation(address: false)
        present(text: text, openInNewTab: openInNewTab)
        if !text.isEmpty { scheduleQuery(for: text) }
    }

    /// A split chooser starts with recent tabs and stays above its empty pane.
    func openSplit(recentResults: [CommandResult], anchor: NSView? = nil) {
        configurePresentation(address: false)
        splitAnchor = anchor
        isSplitMode = true
        initialSplitResults = recentResults
        configureLauncherPresentation()
        present(text: "", openInNewTab: true)
        setResults(recentResults)
        superview?.layoutSubtreeIfNeeded()
        select(0)
        updateSplitPosition()
    }

    /// New Tab is a transient question over the whole window. Choosing an
    /// existing page switches to it; opening and cancelling never adds a tab.
    func openNewTab(recentResults: [CommandResult]) {
        configurePresentation(address: false)
        setCenteredWidth(wholeWindow: true)
        initialNewTabResults = Array(recentResults.prefix(CommandBarMetrics.newTabRecentLimit))
        configureLauncherPresentation()
        present(text: "", openInNewTab: true)
        setResults(initialNewTabResults)
        superview?.layoutSubtreeIfNeeded()
        select(0)
        updateSplitPosition()
    }

    private func configureLauncherPresentation() {
        usesLauncherRows = true
        preferredWidth.constant = 765
        fieldHeight.constant = 64
        field.font = .systemFont(ofSize: CommandBarMetrics.queryFontSize, weight: .medium)
        fieldLeading.constant = 52
        addressIconLeading.constant = 24
        configureArcResultGeometry()
        addressIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        addressIcon.contentTintColor = Style.Colors.primaryText
        addressIcon.isHidden = false
        field.placeholderString = "Search or Enter URL…"
        field.setAccessibilityLabel("Search or Enter URL…")
    }

    private func configureArcResultGeometry() {
        resultsContainer.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 12, right: 10)
        for width in listWidths { width.constant = -20 }
        rowsStack.spacing = CommandBarMetrics.splitRowSpacing
        dividerHeight.constant = 0.5
    }

    /// Command-L edits the current page in the large, centred launcher.
    /// Pointer entry remains the small sidebar popup below.
    func openLocation(text: String, image: NSImage? = nil, suggestions: [CommandResult],
                      loadSuggestions: (@MainActor () async -> [CommandResult])? = nil) {
        configurePresentation(address: false)
        setCenteredWidth(wholeWindow: true)
        configureLauncherPresentation()
        isLocationMode = true
        addressIcon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        addressIcon.contentTintColor = image == nil ? Style.Colors.secondaryText : nil
        initialLocationResults = suggestions
        present(text: text, openInNewTab: false)
        setResults(suggestions)
        superview?.layoutSubtreeIfNeeded()
        select(0)
        updateSplitPosition()
        loadInitialSuggestions(loadSuggestions, for: text)
    }

    /// Editing an existing URL stays beside the sidebar, with local recent tabs ready immediately.
    func openAddress(text: String, anchor: NSView, image: NSImage? = nil, recentResults: [CommandResult] = [],
                     loadSuggestions: (@MainActor () async -> [CommandResult])? = nil) {
        addressAnchor = anchor
        initialAddressResults = recentResults
        addressIcon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        addressIcon.contentTintColor = image == nil ? Style.Colors.secondaryText : nil
        configurePresentation(address: true)
        present(text: text, openInNewTab: false)
        setResults(recentResults)
        superview?.layoutSubtreeIfNeeded()
        select(0)
        loadInitialSuggestions(loadSuggestions, for: text)
    }

    private func loadInitialSuggestions(_ loader: (@MainActor () async -> [CommandResult])?, for text: String) {
        guard let loader else { return }
        let address = isAddressMode, location = isLocationMode
        queryTask = Task { [weak self] in
            let found = await loader()
            guard !Task.isCancelled, let self, self.isOpen,
                  self.isAddressMode == address, self.isLocationMode == location, self.queryText == text else { return }
            if address { self.initialAddressResults = found }
            else { self.initialLocationResults = found }
            self.setResults(found)
            self.select(0)
        }
    }

    private func configurePresentation(address: Bool) {
        NSLayoutConstraint.deactivate(isAddressMode ? addressConstraints : centeredConstraints)
        isAddressMode = address
        addressIconLeading.constant = 16
        resultsContainer.edgeInsets = NSEdgeInsets(top: 0, left: CommandBarMetrics.listInset,
            bottom: CommandBarMetrics.listInset, right: CommandBarMetrics.listInset)
        for width in listWidths { width.constant = -2 * CommandBarMetrics.listInset }
        rowsStack.spacing = CommandBarMetrics.rowSpacing
        dividerHeight.constant = CommandBarMetrics.dividerHeight
        isSplitMode = false
        isLocationMode = false
        usesLauncherRows = false
        initialSplitResults = []
        initialNewTabResults = []
        initialLocationResults = []
        splitAnchor = nil
        centeredConstraints[0].constant = 0
        centeredConstraints[1].constant = 0
        setCenteredWidth(wholeWindow: false)
        preferredWidth.constant = address ? CommandBarMetrics.addressPanelWidth : CommandBarMetrics.panelWidth
        fieldHeight.constant = address ? CommandBarMetrics.addressFieldHeight : CommandBarMetrics.fieldHeight
        fieldLeading.constant = address ? 44 : CommandBarMetrics.fieldInset
        field.font = .systemFont(ofSize: address ? 14 : CommandBarMetrics.queryFontSize)
        addressIcon.isHidden = !address
        field.setAccessibilityLabel(address ? "Edit Address" : "Search, enter address, or type a command")
        field.placeholderString = address ? "Search or Enter URL…" : "Search, enter address, or type a command"
        setAccessibilityLabel(address ? "Address popup" : "Command Bar")
        if address {
            fieldLeading.constant = 52
            addressIconLeading.constant = 24
            configureArcResultGeometry()
        }
        if !address { addressAnchor = nil; initialAddressResults = [] }
        updateAddressPosition()
        NSLayoutConstraint.activate(address ? addressConstraints : centeredConstraints)
        needsLayout = true
    }

    private func setCenteredWidth(wholeWindow: Bool) {
        centeredConstraints[2].isActive = false
        let host = wholeWindow ? self : (centerHost ?? self)
        centeredConstraints[2] = shadowHost.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor,
            constant: -2 * CommandBarMetrics.minimumSideGap)
        centeredConstraints[2].isActive = !isAddressMode
    }

    private func present(text: String, openInNewTab: Bool) {
        queryTask?.cancel()
        queryTask = nil
        isNewTabMode = openInNewTab
        if !isOpen {
            previousResponder = window?.firstResponder
        }
        isHidden = false
        superview?.addSubview(self, positioned: .above, relativeTo: nil)
        field.stringValue = text
        typedQuery = text
        hasEditedQuery = false
        setResults([])
        window?.makeFirstResponder(field)
        applyTextSelection()
        field.currentEditor()?.selectAll(nil)
    }

    /// Hides the bar and gives focus back. Everything typed is discarded: the
    /// bar is a question, and a question that is dismissed has no answer worth
    /// keeping until next time.
    func close(committing: Bool = false) {
        guard isOpen else { return }
        isNewTabMode = false
        queryTask?.cancel()
        queryTask = nil
        restoreTextSelection()
        isHidden = true
        field.stringValue = ""
        setResults([])
        if !committing { onCancel?() }
        restoreResponder()
        onClose?()
    }

    /// Cmd-L: open the bar; close it if it is open and being typed into; and
    /// if it is open but the page has the keyboard, give it back to the bar
    /// with the text selected, which is what the shortcut means everywhere.
    func toggle() {
        guard isOpen else { open(); return }
        // Open, but the keyboard is elsewhere because a click moved it: Cmd-L
        // brings it back rather than closing a bar the user cannot type into.
        // Only with a real window to read focus from; otherwise close as usual.
        if window != nil, !fieldHasFocus { focusField(); return }
        close()
    }

    /// Whether keystrokes reach the bar: the field editor is the responder
    /// while the field is being edited, so the field itself never is.
    var fieldHasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === field { return true }
        return (responder as? NSTextView)?.delegate === field
    }

    func focusField() {
        window?.makeFirstResponder(field)
        applyTextSelection()
        field.currentEditor()?.selectAll(nil)
    }

    /// Hands first responder back to whatever had it, which is the page.
    ///
    /// The fallback is the window itself rather than a guess at which view
    /// ought to have focus: an unfocused window is recoverable with one click,
    /// while focusing the wrong view sends the next keystroke somewhere the
    /// user cannot see.
    private func restoreResponder() {
        guard let window else { return }
        if let previous = previousResponder as? NSView,
           previous.window === window,
           !previous.isDescendant(of: self) {
            window.makeFirstResponder(previous)
        } else {
            window.makeFirstResponder(nil)
        }
        previousResponder = nil
    }

    // MARK: - Results

    /// Replaces the list, rebuilds the rows and drops any selection.
    ///
    /// The selection is not carried across: after a keystroke the row that was
    /// under the cursor may mean something else entirely, and a launcher that
    /// keeps a stale selection is one that opens the wrong page on Return.
    func setResults(_ newResults: [CommandResult]) {
        results = newResults
        selectedIndex = nil
        rebuildRows()
    }

    private func rebuildRows() {
        let fitting = maximumRows
        visibleResults = Array(results.prefix(fitting))
        let selectionWasClipped = selectedIndex.map { !visibleResults.indices.contains($0) } ?? false
        if selectionWasClipped {
            selectedIndex = visibleResults.isEmpty ? nil : visibleResults.count - 1
        }

        for view in rowsStack.arrangedSubviews {
            if let row = view as? CommandRowView {
                row.isSelected = false
                row.onClick = nil
                row.onHover = nil
            }
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, result) in visibleResults.enumerated() {
            let row = CommandRowView()
            row.setAccessibilityIndex(index)
            row.selectionColor = selectionColor
            row.configure(result, image: resultImageProvider?(result), compact: isAddressMode,
                          splitChoice: usesLauncherRows && !isLocationMode, locationChoice: isLocationMode)
            row.onHover = { [weak self] in self?.select(index) }
            row.onClick = { [weak self] in self?.run(at: index) }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        resultsContainer.isHidden = visibleResults.isEmpty
        applySelectionToRows()
        if selectionWasClipped { previewSelection() }
    }

    /// How many rows fit inside the centered panel's vertical margins.
    /// A launcher whose list runs off the screen is worse than a
    /// shorter list, and this is cheaper and steadier than a scroll view for a
    /// list that is capped at eight rows anyway.
    static func maximumVisibleRows(inHeight height: CGFloat, rowHeight: CGFloat = CommandBarMetrics.rowHeight,
                                   fieldHeight: CGFloat = CommandBarMetrics.fieldHeight,
                                   rowSpacing: CGFloat = CommandBarMetrics.rowSpacing) -> Int {
        let chrome = CommandBarMetrics.verticalGap * 2
            + fieldHeight
            + CommandBarMetrics.dividerHeight
            + CommandBarMetrics.listInset * 2
            + CommandBarMetrics.bottomGap
        let available = height - chrome
        guard available > 0 else { return 0 }
        let pitch = rowHeight + rowSpacing
        return max(0, Int((available + rowSpacing) / pitch))
    }

    /// A resize can change how many rows fit, and the list has to follow it or
    /// a taller window keeps a truncated list forever.
    override func layout() {
        super.layout()
        updateSplitPosition()
        updateAddressPosition()
        let expected = min(maximumRows, results.count)
        if expected != visibleResults.count { rebuildRows() }
    }

    private func updateSplitPosition() {
        if let anchor = splitAnchor, let centerHost {
            let rect = convert(anchor.bounds, from: anchor)
            let center = convert(centerHost.bounds, from: centerHost)
            let width = min(preferredWidth.constant, max(0, center.width - 2 * CommandBarMetrics.minimumSideGap))
            let inset = min(80, max(0, (bounds.width - width) / 2))
            let x = min(max(rect.midX, bounds.minX + inset + width / 2), bounds.maxX - inset - width / 2)
            centeredConstraints[0].constant = x - center.midX
            // Anchor rectangles use AppKit's upward Y; layout constants run
            // downward. Arc's chooser rests just above the pane's centre.
            centeredConstraints[1].constant = center.midY - rect.midY - 10
        } else if usesLauncherRows, let centerHost {
            let center = convert(centerHost.bounds, from: centerHost)
            centeredConstraints[0].constant = bounds.midX - center.midX
            centeredConstraints[1].constant = center.midY - bounds.midY - 5
        }
    }

    private func updateAddressPosition() {
        guard isAddressMode, let addressAnchor, addressAnchor.window === window else { return }
        let rect = addressAnchor.convert(addressAnchor.bounds, to: self)
        let width = min(CommandBarMetrics.addressPanelWidth, max(0, bounds.width - 8))
        let onRight = rect.midX > bounds.midX
        let desiredX = onRight ? rect.maxX + 4 - width : rect.minX - 4
        addressLeading.constant = max(4, min(desiredX, bounds.width - width - 4))
        addressTop.constant = max(4, min(bounds.maxY - rect.maxY - 4,
                                       bounds.height - CommandBarMetrics.addressFieldHeight - CommandBarMetrics.bottomGap))
    }

    private var maximumRows: Int {
        guard isAddressMode else {
            return Self.maximumVisibleRows(inHeight: bounds.height - (usesLauncherRows ? 6 : 0),
                rowHeight: usesLauncherRows ? CommandBarMetrics.splitRowHeight : CommandBarMetrics.rowHeight,
                fieldHeight: usesLauncherRows ? 64 : CommandBarMetrics.fieldHeight,
                rowSpacing: usesLauncherRows ? CommandBarMetrics.splitRowSpacing : CommandBarMetrics.rowSpacing)
        }
        let available = bounds.height - addressTop.constant - CommandBarMetrics.addressFieldHeight
            - CommandBarMetrics.bottomGap - 0.5 - CommandBarMetrics.listInset - 12
        return max(0, min(8, Int((available + CommandBarMetrics.splitRowSpacing)
                                / (CommandBarMetrics.splitRowHeight + CommandBarMetrics.splitRowSpacing))))
    }

    // MARK: - Selection

    /// Arc wraps from either end of the list. Keyboard navigation previews
    /// the destination without submitting it or fetching a new result list.
    func moveSelection(by delta: Int) {
        guard !visibleResults.isEmpty else { return }
        let count = visibleResults.count
        let start = selectedIndex ?? (delta > 0 ? -1 : 0)
        select(((start + delta) % count + count) % count)
        previewSelection()
    }

    private func previewSelection(automatically: Bool = false) {
        guard let selectedIndex, visibleResults.indices.contains(selectedIndex) else { return }
        let result = visibleResults[selectedIndex]
        guard result.completionText != nil || !typedQuery.isEmpty else { return }
        let value = result.completionText ?? typedQuery
        let prefix = (value as NSString).range(of: typedQuery, options: [.anchored, .caseInsensitive])
        // A selected title match is useful without replacing the user's search
        // with an unrelated-looking URL. Explicit navigation still previews it.
        if !automatically || prefix.location == 0 {
            field.stringValue = value
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = value
                let length = (value as NSString).length
                let range: NSRange
                if (typedQuery.isEmpty || !hasEditedQuery) && (isLocationMode || isAddressMode) {
                    range = NSRange(location: 0, length: length)
                } else if prefix.location == 0 {
                    range = NSRange(location: prefix.length, length: length - prefix.length)
                } else {
                    range = NSRange(location: length, length: 0)
                }
                editor.setSelectedRange(range)
            }
        }
        if usesLauncherRows || isAddressMode {
            let image = resultImageProvider?(result)
            addressIcon.image = image ?? NSImage(systemSymbolName: result.symbolName, accessibilityDescription: nil)
            addressIcon.contentTintColor = image == nil ? Style.Colors.secondaryText : nil
        }
    }

    func select(_ index: Int?) {
        guard let index else {
            selectedIndex = nil
            applySelectionToRows()
            return
        }
        guard visibleResults.indices.contains(index) else { return }
        selectedIndex = index
        applySelectionToRows()
    }

    private func applySelectionToRows() {
        var changed = false
        for (index, view) in rowsStack.arrangedSubviews.enumerated() {
            guard let row = view as? CommandRowView else { continue }
            let selected = index == selectedIndex
            changed = changed || row.isSelected != selected
            row.isSelected = selected
        }
        if changed, isOpen, window != nil { NSAccessibility.post(element:rowsStack,notification:.selectedRowsChanged) }
    }

    // MARK: - Running

    private func run(at index: Int) {
        guard visibleResults.indices.contains(index) else { return }
        let action = visibleResults[index].action
        let openInNewTab = isNewTabMode
        close(committing: true)
        onRun?(action, openInNewTab)
    }

    /// Return. A selected row wins; otherwise the typed text is resolved the
    /// same way the omnibox resolves it, so "barc" searches and "barc.dev"
    /// navigates without the two needing different keystrokes.
    func submit() {
        if let selectedIndex {
            run(at: selectedIndex)
            return
        }
        let text = field.stringValue
        let engine = searchEngineProvider?() ?? Settings.shared.searchEngine
        guard let url = URLResolver.resolve(text, using: engine, engines: Settings.shared.searchEngines) else { return }
        if NSEvent.modifierFlags.contains(.command) {
            isNewTabMode = true
        }
        let openInNewTab = isNewTabMode
        close(committing: true)
        onRun?(.openURL(url), openInNewTab)
    }

    // MARK: - Querying

    private func scheduleQuery(for text: String) {
        queryTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let resultsProvider else {
            setResults([])
            return
        }
        queryTask = Task { [weak self] in
            try? await Task.sleep(for: CommandBarMetrics.typingDelay)
            guard !Task.isCancelled, let self else { return }
            let found = await resultsProvider(query)
            // The text can have moved on while the database was read; showing
            // rows for a query that is no longer on screen is worse than none.
            guard !Task.isCancelled,
                  self.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            self.setResults(found)
            self.select(0)
            self.previewSelection(automatically:true)
        }
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShadowColor()
    }

    /// A `CGColor` does not follow the appearance, so the one colour in this
    /// component that has to be a `CGColor` is re-resolved by hand -- the same
    /// exception `ContentContainerView` makes, for the same reason.
    private func applyShadowColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shadowHost.layer?.shadowColor = NSColor.shadowColor.cgColor
        }
    }

    // MARK: - Events

    /// A click that lands on the bar and not on the panel is a click outside
    /// the panel, because the panel is the only thing on it.
    override func mouseDown(with event: NSEvent) {
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// A window shares one field editor between controls. Restore its exact
    /// attributes before another control starts editing, including on submit.
    private func applyTextSelection() {
        guard isOpen, let editor = field.currentEditor() as? NSTextView,
              editor.delegate === field else { return }
        if themedEditor !== editor {
            restoreTextSelection()
            themedEditor = editor
            originalSelectionAttributes = editor.selectedTextAttributes
        }
        var attributes = editor.selectedTextAttributes
        attributes[.backgroundColor] = textSelectionColor
        attributes[.foregroundColor] = field.textColor ?? Style.Colors.primaryText
        editor.selectedTextAttributes = attributes
        editor.needsDisplay = true
    }

    private func restoreTextSelection() {
        if let themedEditor, let originalSelectionAttributes {
            themedEditor.selectedTextAttributes = originalSelectionAttributes
        }
        themedEditor = nil
        originalSelectionAttributes = nil
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) {
        applyTextSelection()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        restoreTextSelection()
    }

    func controlTextDidChange(_ obj: Notification) {
        typedQuery = field.stringValue
        hasEditedQuery = true
        if usesLauncherRows, !isSplitMode, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryTask?.cancel()
            queryTask = nil
            setResults(isLocationMode ? initialLocationResults : initialNewTabResults)
            select(0)
            return
        }
        if isSplitMode, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryTask?.cancel()
            queryTask = nil
            setResults(initialSplitResults)
            select(0)
            return
        }
        if isAddressMode, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryTask?.cancel()
            queryTask = nil
            setResults(initialAddressResults)
            select(0)
            return
        }
        // Return immediately after typing must use the new text, even before
        // the debounced provider has replaced a previously selected suggestion.
        setResults([])
        scheduleQuery(for: field.stringValue)
    }

    /// The keyboard contract, in one place: arrows move the selection, Return
    /// runs it, Escape dismisses.
    ///
    /// Handled here rather than by making the bar first responder, so the field
    /// keeps focus throughout: the user is always typing, even while walking
    /// the list, and one more keystroke can narrow it again.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertTab(_:)):
            if let selectedIndex, visibleResults.indices.contains(selectedIndex) {
                let item = visibleResults[selectedIndex]
                let fillText: String
                if let completion = item.completionText { fillText = completion }
                else {
                    switch item.kind {
                    case .address, .search, .command, .space, .folder:
                        fillText = item.title
                    case .openTab, .history, .bookmark:
                        fillText = item.subtitle
                    }
                }
                field.stringValue = fillText
                typedQuery = fillText
                hasEditedQuery = true
                field.currentEditor()?.moveToEndOfLine(nil)
                scheduleQuery(for: fillText)
                return true
            }
            return false
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}
