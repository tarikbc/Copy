import CopyCore
import SwiftUI
import UniformTypeIdentifiers

/// Frames of each pinboard tab, keyed by pinboard id, in the shelf's `"shelfRoot"`
/// coordinate space. Each `TabPill` publishes its own frame; `ShelfRootView` collects them
/// so `ShelfHostingView` can tell which tab a drag is over.
///
/// Drops onto the tabs are not SwiftUI `.onDrop`s. A per-tab `.onDrop` never establishes a
/// working drop region on the small pills inside the shelf's borderless, non-activating
/// glass panel. A shelf-level `.onDrop` puts a full-size SwiftUI drop view over the whole
/// shelf that claims every drag (it registers for `public.item`), so AppKit never hands a
/// card drag to anything else, and SwiftUI stops updating a drag that starts in the card
/// row once it crosses into the header. So the shelf's hosting view takes both drags in
/// AppKit and maps the pointer to a tab via these frames.
struct PinboardTabFramesKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] { [:] }
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Maps a point in the shelf's top-left coordinate space (`"shelfRoot"`, which is also the
/// hosting view's) to the pinboard tab under it, using the frames each tab publishes. The
/// full shelf lays its tabs out in a row; the mini shelf in a column (`vertical`).
enum PinboardTabHitTest {
    static func pinboard(at point: CGPoint, in frames: [Int64: CGRect], vertical: Bool = false) -> Int64? {
        guard !frames.isEmpty else { return nil }
        // Exact hit first (cursor squarely inside a pill).
        if let hit = frames.first(where: { $0.value.contains(point) })?.key { return hit }
        // A column is a row turned on its side: swap the axes and resolve it the same way.
        guard vertical else { return nearest(to: point, in: frames) }
        let swapped = frames.mapValues { CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width) }
        return nearest(to: CGPoint(x: point.y, y: point.x), in: swapped)
    }

    /// Resolves by column, not by an inflated rectangle: the pills are only ~24pt tall and
    /// sit in a single row, so matching a raw point against thin, near-touching frames misses
    /// at edges and picks arbitrarily where inflated frames overlap. Instead, accept any drop
    /// within the tab-row's vertical band and map it to the tab whose X range holds the
    /// cursor — or the nearest tab center when between columns.
    private static func nearest(to point: CGPoint, in frames: [Int64: CGRect]) -> Int64? {
        let rowTop = frames.values.map(\.minY).min() ?? 0
        let rowBottom = frames.values.map(\.maxY).max() ?? 0
        guard point.y >= rowTop - 14, point.y <= rowBottom + 14 else { return nil }
        if let column = frames.first(where: { point.x >= $0.value.minX && point.x <= $0.value.maxX })?.key {
            return column
        }
        return frames.min(by: { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) })?.key
    }
}

/// A drag that started in the shelf, as recorded when it began.
enum ShelfDrag {
    /// One card, or a multi-selection's uuids in order.
    case cards([String])
    /// A pinboard tab being reordered.
    case pinboard(Int64)

    enum Kind { case cards, pinboard }

    var kind: Kind {
        switch self {
        case .cards: .cards
        case .pinboard: .pinboard
        }
    }
}

/// What the drop callout under the pinboard tabs shows (see `PinboardDropCalloutLayer`).
struct PinboardDropCallout: Equatable {
    enum Phase {
        /// A card drag is over the tab: names the board it will be filed into.
        case targeting
        /// The drop landed: a short confirmation before the callout folds away.
        case filed
    }

    var pinboardID: Int64
    /// Cards being dragged, or cards actually added once filed.
    var count: Int
    var phase: Phase
    /// Tells two otherwise equal callouts apart, so a confirmation's timer only clears
    /// the confirmation it started.
    let token = UUID()
}

/// The callout that pops out of the pinboard tab under a card drag, naming the board the
/// card will land in (the tab alone is small, and the drag chip sits on top of it), then
/// briefly confirms the drop. It glides from tab to tab as the
/// drag moves along the row. Laid over the whole shelf in the `"shelfRoot"` space, where
/// the tab frames are measured, so it can hang below the header over the cards. In the
/// mini shelf's pinboard column (`vertical`) it pops out to the side of the tab instead.
struct PinboardDropCalloutLayer: View {
    let callout: PinboardDropCallout?
    let pinboards: [Pinboard]
    let tabFrames: [Int64: CGRect]
    var vertical: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let callout,
               let pinboard = pinboards.first(where: { $0.id == callout.pinboardID }),
               let tab = tabFrames[callout.pinboardID] {
                // Positioned by alignment guides, not `.offset`, so the view's real frame
                // sits beside the tab: the pop-out transition then scales from the tab,
                // and moving to another tab animates as a layout change.
                if vertical {
                    PinboardDropCalloutView(callout: callout, pinboard: pinboard, arrowEdge: .leading,
                                            arrowOffset: nil)
                        .alignmentGuide(.leading) { _ in -(tab.maxX + 3) }
                        .alignmentGuide(.top) { d in -(tab.midY - d.height / 2) }
                        .transition(reduceMotion
                            ? .opacity
                            : .scale(scale: 0.35, anchor: .leading).combined(with: .opacity))
                } else {
                    PinboardDropCalloutView(callout: callout, pinboard: pinboard, arrowEdge: .top,
                                            arrowOffset: tab.width / 2 + Self.leadingInset)
                        .alignmentGuide(.leading) { _ in -(tab.minX - Self.leadingInset) }
                        .alignmentGuide(.top) { _ in -(tab.maxY + 3) }
                        .transition(reduceMotion
                            ? .opacity
                            : .scale(scale: 0.35, anchor: UnitPoint(x: 0.12, y: 0)).combined(with: .opacity))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.72),
                   value: callout)
    }

    /// How far the callout starts left of its tab, so short names still read as hanging
    /// from the tab rather than starting exactly at its edge.
    private static let leadingInset: CGFloat = 6
}

private struct PinboardDropCalloutView: View {
    let callout: PinboardDropCallout
    let pinboard: Pinboard
    /// The edge the arrow points out of, toward the tab.
    let arrowEdge: CalloutShape.ArrowEdge
    /// The arrow's position along that edge, from its start; nil centers it.
    let arrowOffset: CGFloat?

    private var boardColor: Color {
        pinboard.tint.isEmpty ? .accentColor : Tokens.color(fromHex: pinboard.tint)
    }

    private var isFiled: Bool { callout.phase == .filed }

    private var caption: String {
        switch (callout.phase, callout.count) {
        case (.targeting, 1): "Add to"
        case (.targeting, let count): "Add \(count) items to"
        case (.filed, 1): "Added to"
        case (.filed, let count): "Added \(count) items to"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            badge
            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(pinboard.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .contentTransition(.interpolate)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .padding(arrowEdge == .top ? .top : .leading, CalloutShape.arrowHeight)
        .fixedSize()
        // Plain system material with a hairline, like a native popover: the board's color
        // lives only in the badge, the same small dose of it the tab itself carries.
        .background {
            let shape = CalloutShape(arrowEdge: arrowEdge, arrowOffset: arrowOffset)
            shape.fill(.regularMaterial)
            shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }

    /// The board's emoji, else its color, in a small disc; a check once the drop lands.
    @ViewBuilder private var badge: some View {
        ZStack {
            Circle().fill(boardColor.opacity(isFiled ? 0.9 : 0.22))
            if isFiled {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            } else if let emoji = pinboard.emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: 13))
            } else {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(boardColor)
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// A rounded bubble with a small arrow pointing at the tab: on top for the full shelf's
/// tab row, on the leading side for the mini shelf's column.
struct CalloutShape: Shape {
    enum ArrowEdge { case top, leading }

    static let arrowHeight: CGFloat = 6
    private static let arrowWidth: CGFloat = 14
    private static let cornerRadius: CGFloat = 10

    var arrowEdge: ArrowEdge
    /// Along the arrow's edge, from its start; nil centers it.
    var arrowOffset: CGFloat?

    var animatableData: CGFloat {
        get { arrowOffset ?? 0 }
        set { if arrowOffset != nil { arrowOffset = newValue } }
    }

    func path(in rect: CGRect) -> Path {
        let inset = Self.arrowHeight
        let body = arrowEdge == .top
            ? CGRect(x: rect.minX, y: rect.minY + inset, width: rect.width, height: rect.height - inset)
            : CGRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset, height: rect.height)
        let bubble = Path(roundedRect: body, cornerRadius: Self.cornerRadius, style: .continuous)
        let halfWidth = Self.arrowWidth / 2
        let margin = Self.cornerRadius + halfWidth
        var arrow = Path()
        switch arrowEdge {
        case .top:
            let x = min(max(rect.minX + (arrowOffset ?? rect.width / 2), body.minX + margin), body.maxX - margin)
            arrow.move(to: CGPoint(x: x - halfWidth, y: body.minY + 1))
            arrow.addQuadCurve(to: CGPoint(x: x, y: rect.minY), control: CGPoint(x: x - 2, y: body.minY))
            arrow.addQuadCurve(to: CGPoint(x: x + halfWidth, y: body.minY + 1), control: CGPoint(x: x + 2, y: body.minY))
        case .leading:
            let y = min(max(rect.minY + (arrowOffset ?? rect.height / 2), body.minY + margin), body.maxY - margin)
            arrow.move(to: CGPoint(x: body.minX + 1, y: y - halfWidth))
            arrow.addQuadCurve(to: CGPoint(x: rect.minX, y: y), control: CGPoint(x: body.minX, y: y - 2))
            arrow.addQuadCurve(to: CGPoint(x: body.minX + 1, y: y + halfWidth), control: CGPoint(x: body.minX, y: y + 2))
        }
        arrow.closeSubpath()
        return bubble.union(arrow)
    }
}
