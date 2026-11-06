import AppKit
import CopyCore
import SwiftUI

func pasteStackCallerDescription(_ caller: PasteStackCaller?) -> String? {
    guard let caller else { return nil }
    let verified = caller.signingID?.isEmpty == false && caller.certificateSHA256?.isEmpty == false
    let description = String((caller.bundleID + " (" + caller.canonicalPath + ")").prefix(500))
    let safe = description.unicodeScalars.map { scalar in
        CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .format
            ? String(format: "⟦U+%04X⟧", scalar.value) : String(scalar)
    }.joined()
    return verified ? safe : "Unverified app: " + safe
}

private let batchPreviewLimit = 2_000
private let secretScanLimit = 250_000

private func batchPreviewRanges(_ text: String) -> [NSRange] {
    let source = text as NSString
    var ranges: [NSRange] = []
    var start = 0
    while start < source.length {
        var end = min(start + batchPreviewLimit, source.length)
        if end < source.length, (0xD800...0xDBFF).contains(source.character(at: end - 1)),
           (0xDC00...0xDFFF).contains(source.character(at: end)) {
            end -= 1
        }
        ranges.append(NSRange(location: start, length: end - start))
        start = end
    }
    return ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges
}

func pasteStackPreviewPageCount(_ text: String) -> Int { batchPreviewRanges(text).count }

func pasteStackPreviewText(_ text: String, hideSecrets: Bool, revealed: Bool, page: Int = 0) -> String {
    let ranges = batchPreviewRanges(text)
    guard ranges.indices.contains(page) else { return "" }
    let oversized = (text as NSString).length > secretScanLimit
    if hideSecrets && !revealed && oversized {
        return "This item is too long to scan for secrets. Select Show content to review it."
    }
    let display = hideSecrets && !revealed ? SecretDetector.masked(text) : text
    let chunk = (display as NSString).substring(with: ranges[page])
    return chunk.unicodeScalars.map { scalar in
        if CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .format {
            return String(format: "⟦U+%04X⟧", scalar.value)
        }
        return String(scalar)
    }.joined()
}

struct BatchReviewList: View {
    let texts: [String]
    let hideSecrets: Bool
    @State private var revealed: Set<Int> = []
    @State private var pages: [Int: Int] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(texts.indices, id: \.self) { index in
                    let text = texts[index]
                    let oversized = (text as NSString).length > secretScanLimit
                    let hasSecret = hideSecrets && (oversized || SecretDetector.masked(text) != text)
                    let total = pasteStackPreviewPageCount(text)
                    let page = min(pages[index] ?? 0, total - 1)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Item \(index + 1)").font(.caption.weight(.semibold))
                            Spacer()
                            if hasSecret {
                                Button(revealed.contains(index) ? "Hide content" : "Show content") {
                                    if revealed.contains(index) { revealed.remove(index) }
                                    else { revealed.insert(index) }
                                }
                                .buttonStyle(.link)
                            }
                        }
                        Text(verbatim: pasteStackPreviewText(text, hideSecrets: hideSecrets,
                                                            revealed: revealed.contains(index), page: page))
                            .textSelection(.enabled)
                        if total > 1 && (!oversized || !hideSecrets || revealed.contains(index)) {
                            HStack {
                                Button("Previous") { pages[index] = page - 1 }.disabled(page == 0)
                                Text("Page \(page + 1) of \(total)").font(.caption)
                                Button("Next") { pages[index] = page + 1 }.disabled(page + 1 == total)
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(4)
        }
        .frame(width: 440, height: 220)
    }
}

@MainActor
func pasteStackBatchConfirmation(_ texts: [String], hideSecrets: Bool, hideDuringScreenSharing: Bool,
                                 caller: String? = nil, canRemember: Bool = false,
                                 hasExistingItems: Bool = true) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Add items to Paste Stack?"
    let source = caller ?? "An action with an unverified origin"
    let action = hasExistingItems ? "replace your Paste Stack with" : "add to your Paste Stack"
    alert.informativeText = "\(source) wants to \(action) \(texts.count) text items. Review the items below."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: hasExistingItems ? "Replace Stack" : "Allow Once")
    if canRemember { alert.addButton(withTitle: "Allow and Remember") }
    alert.buttons[0].keyEquivalent = "\r"
    for button in alert.buttons.dropFirst() { button.keyEquivalent = "" }
    let preview = NSHostingView(rootView: BatchReviewList(texts: texts, hideSecrets: hideSecrets))
    preview.frame = NSRect(x: 0, y: 0, width: 440, height: 220)
    alert.accessoryView = preview
    alert.window.sharingType = hideDuringScreenSharing ? .none : .readOnly
    return alert
}
