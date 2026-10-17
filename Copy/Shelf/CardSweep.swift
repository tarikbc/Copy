import SwiftUI

/// Card frames by item uuid, in the row's content space.
struct CardFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Drag-select geometry: the rectangle swept from the shelf's empty space, the cards it
/// touches, and edge scrolling. `ShelfViewModel` turns the touched cards into the selection.
/// Points come in the shelf's `"shelfRoot"` space; the rectangle is kept in content space
/// so its starting corner stays with the cards while the row scrolls.
@MainActor
@Observable
final class CardSweep {
    static let viewportSpace = "shelfRowViewport"
    static let contentSpace = "shelfRowContent"

    /// In content space; nil when not sweeping.
    private(set) var rect: CGRect?

    @ObservationIgnored private var cardFrames: [String: CGRect] = [:]
    @ObservationIgnored private var contentOrigin: CGPoint = .zero
    /// The row's visible area, in shelf space.
    @ObservationIgnored var viewportFrame: CGRect = .zero
    /// In content space.
    @ObservationIgnored private var start: CGPoint?
    /// In shelf space.
    @ObservationIgnored private var pointer: CGPoint = .zero
    @ObservationIgnored weak var scrollView: NSScrollView?
    /// Points per tick; negative scrolls toward the leading edge.
    @ObservationIgnored private var edgeScrollStep: CGFloat = 0
    @ObservationIgnored private var edgeScrollTimer: Timer?

    private static let edgeScrollMargin: CGFloat = 44
    private static let edgeScrollMaxStep: CGFloat = 16

    var isActive: Bool { start != nil }

    /// The lazy row drops off-screen cards, so frames accumulate during a sweep to keep
    /// swept cards selected after they scroll away.
    func cardFramesChanged(_ frames: [String: CGRect]) {
        if isActive {
            cardFrames.merge(frames, uniquingKeysWith: { _, new in new })
        } else {
            cardFrames = frames
        }
    }

    /// Returns false when the press is on a card or a draggable (a pinboard tab).
    func begin(at point: CGPoint, avoiding draggables: [CGRect]) -> Bool {
        let origin = contentPoint(point)
        guard !cardFrames.values.contains(where: { $0.contains(origin) }),
              !draggables.contains(where: { $0.contains(point) }) else { return false }
        start = origin
        pointer = point
        refresh()
        return true
    }

    func move(to point: CGPoint) {
        guard isActive else { return }
        pointer = point
        refresh()
    }

    /// The row scrolled. Returns whether a sweep is in progress.
    func contentMoved(to origin: CGPoint) -> Bool {
        contentOrigin = origin
        guard isActive else { return false }
        refresh()
        return true
    }

    func end() {
        start = nil
        rect = nil
        setEdgeScrollStep(0)
    }

    var rectInShelf: CGRect? {
        rect?.offsetBy(dx: contentOrigin.x + viewportFrame.minX, dy: contentOrigin.y + viewportFrame.minY)
    }

    var hits: Set<String> {
        guard let rect else { return [] }
        return Set(cardFrames.filter { $0.value.intersects(rect) }.keys)
    }

    /// The touched card nearest the pointer.
    var nearestHit: String? {
        guard let rect else { return nil }
        let x = contentPoint(pointer).x
        return cardFrames
            .filter { $0.value.intersects(rect) }
            .min(by: { abs($0.value.midX - x) < abs($1.value.midX - x) })?.key
    }

    private func contentPoint(_ shelfPoint: CGPoint) -> CGPoint {
        CGPoint(x: shelfPoint.x - viewportFrame.minX - contentOrigin.x,
                y: shelfPoint.y - viewportFrame.minY - contentOrigin.y)
    }

    private func refresh() {
        guard let start else { return }
        let current = contentPoint(pointer)
        rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
        // Depth into an edge zone: 0 at its start, 1 at the edge.
        let trailing = (pointer.x - (viewportFrame.maxX - Self.edgeScrollMargin)) / Self.edgeScrollMargin
        let leading = ((viewportFrame.minX + Self.edgeScrollMargin) - pointer.x) / Self.edgeScrollMargin
        if trailing > 0 {
            setEdgeScrollStep(min(trailing, 1) * Self.edgeScrollMaxStep)
        } else if leading > 0 {
            setEdgeScrollStep(-min(leading, 1) * Self.edgeScrollMaxStep)
        } else {
            setEdgeScrollStep(0)
        }
    }

    private func setEdgeScrollStep(_ step: CGFloat) {
        edgeScrollStep = step
        if step == 0 {
            edgeScrollTimer?.invalidate()
            edgeScrollTimer = nil
        } else if edgeScrollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.edgeScrollTick() }
            }
            // `.common` keeps it firing while the mouse is held down.
            RunLoop.main.add(timer, forMode: .common)
            edgeScrollTimer = timer
        }
    }

    /// Scrolls the clip view directly, unanimated, so the rectangle tracks it per frame.
    private func edgeScrollTick() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxX = max(0, document.frame.width - clip.bounds.width)
        let x = min(max(clip.bounds.origin.x + edgeScrollStep, 0), maxX)
        guard x != clip.bounds.origin.x else { return }
        clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// The drag-select rectangle, drawn over the whole shelf.
struct CardSweepRectangle: View {
    let sweep: CardSweep

    var body: some View {
        // A path, not a sized view: a view wider than the shelf gets re-centered by
        // layout, which pulls the rectangle away from the pointer once the row scrolls.
        let outline = Path(sweep.rectInShelf ?? .zero)
        ZStack {
            outline.fill(Color.primary.opacity(0.08))
            outline.stroke(Color.primary.opacity(0.28), lineWidth: 1)
        }
        // Never animated, or it trails the pointer.
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Finds the card row's `NSScrollView` from inside its content.
struct CardRowScrollViewFinder: NSViewRepresentable {
    let onFind: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> FinderView {
        let view = FinderView()
        view.onFind = onFind
        return view
    }

    func updateNSView(_ nsView: FinderView, context: Context) {
        nsView.onFind = onFind
    }

    final class FinderView: NSView {
        var onFind: ((NSScrollView?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onFind?(self.enclosingScrollView)
            }
        }
    }
}
