import AppKit
import ApplicationServices

/// Finds the text cursor in the frontmost app through Accessibility, for placing the mini
/// shelf. Returns nil when Accessibility is off or the app doesn't report a usable cursor
/// (many Chromium and Electron apps don't); the caller then falls back to the pointer.
enum CaretLocator {
    /// The caret's rect in AppKit screen coordinates (origin bottom-left).
    static func caretRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        // A hung app must not stall the hotkey.
        AXUIElementSetMessagingTimeout(systemWide, 0.15)
        guard let focused = copyAttribute(kAXFocusedUIElementAttribute, of: systemWide),
              CFGetTypeID(focused) == AXUIElementGetTypeID(),
              let rangeValue = copyAttribute(kAXSelectedTextRangeAttribute, of: focused as! AXUIElement),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }

        // An empty selection often has no bounds, so measure the character after it, then
        // the one before it, and use the edge that touches the caret.
        if let rect = bounds(of: range, in: element) {
            return toAppKit(range.length == 0 ? CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height) : rect)
        }
        if let next = bounds(of: CFRange(location: range.location, length: 1), in: element) {
            return toAppKit(CGRect(x: next.minX, y: next.minY, width: 0, height: next.height))
        }
        if range.location > 0, let previous = bounds(of: CFRange(location: range.location - 1, length: 1), in: element) {
            return toAppKit(CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height))
        }
        return nil
    }

    private static func copyAttribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// The range's bounds in Accessibility's top-left screen space, if the app reports a
    /// real, on-screen rect for it.
    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0,
              rect.origin != .zero else { return nil }
        return rect
    }

    /// Accessibility measures from the primary display's top-left corner; AppKit from its
    /// bottom-left. Rejects a rect that lands on no display.
    private static func toAppKit(_ rect: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let probe = CGPoint(x: flipped.minX, y: flipped.midY)
        guard NSScreen.screens.contains(where: { $0.frame.contains(probe) }) else { return nil }
        return flipped
    }
}
