import AppKit
import SwiftUI

enum ShelfWheelScroll {
    static func horizontalOffset(horizontal: CGFloat, vertical: CGFloat) -> CGFloat? {
        guard horizontal == 0, vertical != 0 else { return nil }
        return -vertical
    }
}

struct ShelfWheelScrollBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ShelfWheelScrollView() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ShelfWheelScrollView: NSView {
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitor()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let scroll = self.enclosingScrollView,
                  event.window === self.window,
                  let offset = ShelfWheelScroll.horizontalOffset(
                    horizontal: event.scrollingDeltaX, vertical: event.scrollingDeltaY),
                  self.contains(event: event, in: scroll) else { return event }

            let maximum = max(0, (scroll.documentView?.frame.width ?? 0) - scroll.contentSize.width)
            let x = min(max(0, scroll.contentView.bounds.origin.x + offset), maximum)
            scroll.contentView.scroll(to: NSPoint(x: x, y: scroll.contentView.bounds.origin.y))
            scroll.reflectScrolledClipView(scroll.contentView)
            return nil
        }
    }

    private func contains(event: NSEvent, in scroll: NSScrollView) -> Bool {
        let point = scroll.contentView.convert(event.locationInWindow, from: nil)
        return scroll.contentView.bounds.contains(point)
    }
}
