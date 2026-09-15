import Foundation

/// Bounded preview sizes in points, preserving the source image aspect ratio.
public enum PreviewLayout {
    public static func imageSize(pixels: CGSize, screen: CGSize, scale: CGFloat) -> CGSize {
        let padding: CGFloat = 24
        let maxWidth = max(1, min(1120, screen.width * 0.78) - padding)
        let maxHeight = max(1, min(720, screen.height * 0.72) - padding)
        var width = max(1, pixels.width) / max(1, scale)
        var height = max(1, pixels.height) / max(1, scale)
        let enlarge = max(1, 520 / max(width, height))
        width *= enlarge
        height *= enlarge
        let fit = min(1, min(maxWidth / width, maxHeight / height))
        return CGSize(width: ceil(width * fit + padding), height: ceil(height * fit + padding))
    }

    public static func textSize(text: String, screen: CGSize) -> CGSize {
        let lines = text.prefix(200_000).split(separator: "\n", omittingEmptySubsequences: false)
        let maxWidth = min(520, screen.width * 0.55)
        let width = min(maxWidth, max(320, CGFloat(lines.map(\.count).max() ?? 0) * 7.2 + 28))
        let perLine = max(1, Int((width - 28) / 7.2))
        let count = lines.reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / Double(perLine)))) }
        return CGSize(width: ceil(width), height: ceil(min(min(620, screen.height * 0.62), max(120, CGFloat(count) * 18 + 28))))
    }
}
