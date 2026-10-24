import Foundation

enum LibraryMetrics {
    static let rail: CGFloat = 112
    static let list: CGFloat = 305
    static let materialStrength: CGFloat = 0.11
}

/// A temporary layout never becomes the user's resting sidebar preference.
struct LibrarySidebarWidth {
    private(set) var resting: CGFloat?
    mutating func show(_ category: LibraryCategory, current: CGFloat) -> CGFloat {
        if resting == nil { resting = current }
        return category == .spaces ? LibraryMetrics.rail : LibraryMetrics.rail + LibraryMetrics.list
    }
    mutating func close() -> CGFloat? { defer { resting = nil }; return resting }
    mutating func updateRestingWidth(_ width: CGFloat) {
        if resting != nil { resting = width }
    }
}
