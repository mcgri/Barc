// Modified for Barc: one compact sidebar row containing the split's pane cells, 2026-10-24.
import AppKit

@MainActor
final class SplitRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SplitRow")
    var onSelectMember: ((Int) -> Void)?
    var onCloseMember: ((Int) -> Void)?
    var onResetMember: ((Int, Bool) -> Bool)?
    var isSelected = false { didSet { updateAppearance() } }
    var indentation: CGFloat = Style.Metrics.sidebarInset { didSet { needsLayout = true } }
    var isInGroupPlate = false { didSet { needsLayout = true } }
    private(set) var focusedIndex: Int?
    private(set) var members: [MemberView] = []
    private var highlight: RowHighlight?
    private var tracking: NSTrackingArea?
    private var isFresh = true
    private var hovered = false { didSet { updateAppearance() } }
    private var contents: [TabRowContent] = []
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        wantsLayer = true
        clipsToBounds = false
        if let layer { highlight = RowHighlight(in:layer) }
    }
    required init?(coder:NSCoder) { fatalError("SplitRowView is created in code only") }

    var pillRect:NSRect {
        // A split's shared plate is one point taller than a plain tab's pill.
        // At the reference density that is 36 points, enclosing 28-point cells.
        let height = Style.Metrics.rowPillHeight + 1
        let inset = (Style.Metrics.rowHeight-height)/2
        // The sidebar stack already leaves the trailing eight-point gutter.
        // Split plates meet that edge and start at the matching leading gutter.
        return NSRect(x:indentation,y:inset,
            width:max(0,bounds.width-indentation-(isInGroupPlate ? Style.Metrics.rowIndent : 0)),
            height:height)
    }

    func configure(_ contents:[TabRowContent], focusedIndex:Int?) {
        self.contents = contents
        self.focusedIndex = focusedIndex
        while members.count > contents.count { members.removeLast().removeFromSuperview() }
        while members.count < contents.count {
            let member = MemberView()
            addSubview(member)
            members.append(member)
        }
        for (index,content) in contents.enumerated() {
            let member = members[index]
            member.show(content)
            member.onActivate = { [weak self] in self?.onSelectMember?(index) }
            member.onClose = { [weak self] in self?.onCloseMember?(index) }
        }
        setAccessibilityLabel("Split View: " + contents.map(\.title).joined(separator:", "))
        needsLayout = true
        updateAppearance()
    }

    func memberIndex(at point:NSPoint) -> Int? {
        members.firstIndex { $0.frame.contains(point) }
    }
    @discardableResult
    func activate(at point:NSPoint, keepingCurrentPage:Bool = false) -> Bool {
        guard let index = memberIndex(at:point) else { return false }
        let member = members[index]
        if contents[index].canResetPinnedPage,
           member.favicon.frame.contains(member.convert(point,from:self)),
           onResetMember?(index,keepingCurrentPage) == true { return true }
        onSelectMember?(index)
        return true
    }

    override func layout() {
        super.layout()
        let rect = pillRect
        highlight?.layout(rect,in:bounds.height,flipped:isFlipped,radius:12,
                          scale:window?.backingScaleFactor ?? 2)
        let gap:CGFloat = 4
        let inner = rect.insetBy(dx:4,dy:4)
        let width = max(0,(inner.width-gap*CGFloat(max(0,members.count-1)))/CGFloat(max(1,members.count)))
        for (index,member) in members.enumerated() {
            member.frame = NSRect(x:inner.minX+CGFloat(index)*(width+gap),y:inner.minY,width:width,height:inner.height)
        }
        if hovered && !isPointerInside { hovered = false }
        if isFresh { isFresh = false; updateAppearance(animated:false) }
    }

    private func updateAppearance(animated:Bool = true) {
        highlight?.apply(isSelected ? .selected : (hovered ? .hover : .rest),appearance:effectiveAppearance,animated:animated && !isFresh)
        for (index,member) in members.enumerated() {
            member.focused = isSelected && index == focusedIndex
            member.groupSelected = isSelected
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight?.refresh(appearance:effectiveAppearance)
        updateAppearance()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking = installHoverTracking(replacing:tracking)
        hovered = isPointerInside
    }
    override func mouseEntered(with event:NSEvent) { hovered = true }
    override func mouseExited(with event:NSEvent) { hovered = false }
    override func prepareForReuse() {
        super.prepareForReuse()
        isFresh = true
        onSelectMember = nil; onCloseMember = nil; onResetMember = nil
        hovered = false; isSelected = false
        configure([],focusedIndex:nil)
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view:NSView? = hit
        while let candidate = view, candidate !== self {
            if let button = candidate as? NSButton { return button }
            view = candidate.superview
        }
        return self
    }

    @MainActor
    final class MemberView:NSView {
        let favicon = FaviconImageView()
        let title = NSTextField(labelWithString:"")
        private let emoji = NSTextField(labelWithString:"")
        private let symbol = NSImageView()
        private let close = NSButton(image:NSImage(systemSymbolName:"xmark",accessibilityDescription:"Close Tab")!,target:nil,action:nil)
        private var content = TabRowContent(title:"")
        private var tracking:NSTrackingArea?
        var onActivate:(() -> Void)?
        var onClose:(() -> Void)?
        var focused = false { didSet { paint() } }
        var groupSelected = false { didSet { paint() } }
        private var hovered = false { didSet { paint(); needsLayout = true } }
        override var isFlipped:Bool { true }
        override init(frame:NSRect) {
            super.init(frame:frame)
            wantsLayer = true; clipsToBounds = true
            layer?.cornerRadius = 8
            for view in [favicon,title,emoji,symbol,close] { addSubview(view) }
            favicon.removeConstraints(favicon.constraints)
            favicon.translatesAutoresizingMaskIntoConstraints = true
            title.font = Style.Fonts.tabTitle
            title.textColor = Style.Colors.primaryText
            title.lineBreakMode = .byTruncatingTail
            title.cell?.usesSingleLineMode = true
            title.setAccessibilityElement(false)
            emoji.font = .systemFont(ofSize:14); emoji.alignment = .center
            emoji.setAccessibilityElement(false); symbol.setAccessibilityElement(false)
            close.isBordered = false; close.bezelStyle = .inline
            close.imageScaling = .scaleProportionallyDown
            close.contentTintColor = Style.Colors.secondaryText
            close.target = self; close.action = #selector(closePressed)
            setAccessibilityElement(true); setAccessibilityRole(.button)
        }
        required init?(coder:NSCoder) { fatalError("MemberView is created in code only") }
        func show(_ content:TabRowContent) {
            self.content = content
            title.stringValue = content.title
            emoji.stringValue = content.emoji ?? ""
            emoji.isHidden = content.emoji == nil
            symbol.image = content.sidebarSymbolName.flatMap { FolderSymbols.image(named:$0) }
            symbol.isHidden = content.emoji != nil || symbol.image == nil
            favicon.isHidden = !emoji.isHidden || !symbol.isHidden
            toolTip = content.address
            setAccessibilityLabel(content.title)
            close.setAccessibilityLabel("Close " + content.title)
            paint(); needsLayout = true
        }
        override func layout() {
            super.layout()
            if hovered && !isPointerInside { hovered = false }
            paint()
            let side = max(0,min(16,bounds.height,bounds.width-12))
            let icon = NSRect(x:6,y:(bounds.height-side)/2,width:side,height:side)
            favicon.frame = icon; emoji.frame = icon; symbol.frame = icon
            // The native label already leaves padding around its glyphs. An
            // extra six points here discarded a whole character at 228 points.
            let right = close.isHidden ? bounds.width : bounds.width-20
            // The reference caption's cap-height center sits half a point
            // below the centered favicon. Shorter custom rows keep the text
            // field inside the cell rather than cutting its top or bottom.
            let textHeight = min(18,bounds.height)
            let clearance = (bounds.height-textHeight)/2
            title.frame = NSRect(x:icon.maxX+10,y:clearance+min(0.5,clearance),width:max(0,right-icon.maxX-10),height:textHeight)
            close.frame = NSRect(x:bounds.width-18,y:(bounds.height-14)/2,width:14,height:14)
            paint()
        }
        private func paint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovered ? 0.12 : (groupSelected ? 0.08 : 0.045)).cgColor
            }
            close.isHidden = !hovered || content.isLocked || bounds.width < 60
            setAccessibilityValue(focused ? "Focused" : "")
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            tracking = installHoverTracking(replacing:tracking)
            hovered = isPointerInside
        }
        override func mouseEntered(with event:NSEvent) { hovered = true }
        override func mouseExited(with event:NSEvent) { hovered = false }
        override func accessibilityPerformPress() -> Bool { onActivate?(); return onActivate != nil }
        @objc private func closePressed() { onClose?() }
    }
}
