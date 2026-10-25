// Modified for Barc: compact naming for icon-only Favorite destinations, 2026-10-25.
import AppKit

@MainActor
final class InlineNamePopover:NSViewController {
    private let name:String
    private let finish:(String?)->Void
    init(name:String,finish:@escaping (String?)->Void) {
        self.name = name;self.finish = finish
        super.init(nibName:nil,bundle:nil)
        preferredContentSize = NSSize(width:270,height:48)
    }
    required init?(coder:NSCoder) { fatalError("Created in code only") }
    override func loadView() {
        view = NSView(frame:NSRect(origin:.zero,size:preferredContentSize))
        let field = FolderNameEditor(name:name,font:Style.Fonts.tabTitle,placeholder:"Favorite name",label:"Favorite name",onFinish:finish)
        field.frame = NSRect(x:12,y:13,width:246,height:22)
        view.addSubview(field)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        (view.subviews.first as? FolderNameEditor)?.beginEditing()
    }
}
