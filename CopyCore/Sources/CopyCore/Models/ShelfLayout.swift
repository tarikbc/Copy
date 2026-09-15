import Foundation

public enum ShelfLayout {
    public static func frame(visibleFrame: CGRect, height: CGFloat, floating: Bool) -> CGRect {
        let inset: CGFloat = floating ? 12 : 0
        return CGRect(x: visibleFrame.minX + inset, y: visibleFrame.minY + inset,
                      width: max(1, visibleFrame.width - inset * 2), height: height)
    }
}
