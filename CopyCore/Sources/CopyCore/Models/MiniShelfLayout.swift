import Foundation

/// Where the mini shelf opens: just above the text cursor (or the pointer, when the app
/// reports no cursor), below it when there isn't room above, and always on screen.
/// AppKit screen coordinates, origin bottom-left.
public enum MiniShelfLayout {
    /// Space between the anchor and the shelf.
    public static let gap: CGFloat = 6
    /// The shelf's closest approach to a screen edge.
    public static let edgeInset: CGFloat = 8
    /// How far left of the anchor the shelf starts, so its cards begin near the cursor.
    public static let leadingOffset: CGFloat = 16

    public struct Placement: Equatable {
        public let frame: CGRect
        public let opensBelow: Bool
    }

    /// `anchor` is the caret's rect, or a zero-size rect at the pointer.
    public static func placement(size: CGSize, anchor: CGRect, visibleFrame: CGRect) -> Placement {
        let bounds = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let roomAbove = bounds.maxY - (anchor.maxY + gap)
        let roomBelow = anchor.minY - gap - bounds.minY
        let opensBelow = roomAbove < height && roomBelow > roomAbove
        let x = min(max(anchor.minX - leadingOffset, bounds.minX), bounds.maxX - width)
        let y = min(max(opensBelow ? anchor.minY - gap - height : anchor.maxY + gap, bounds.minY),
                    bounds.maxY - height)
        return Placement(frame: CGRect(x: x, y: y, width: width, height: height), opensBelow: opensBelow)
    }
}
