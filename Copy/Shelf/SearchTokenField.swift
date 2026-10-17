import CopyCore
import SwiftUI

/// The shelf's faceted search field: a row of facet pills followed by a text field, with a
/// suggestions dropdown floating below while typing. Selecting a suggestion (click, or ⏎ on
/// the keyboard-highlighted row via `AppCoordinator.onKeyEvent`) commits a pill; the trailing
/// text FTS-searches content. Copy's own take on token search — glass dropdown, electric-blue
/// highlight, quiet chips (no colored edge stripes).
struct SearchTokenField: View {
    @Bindable var viewModel: ShelfViewModel
    var placeholder: String
    @FocusState.Binding var focused: Bool

    private var textBinding: Binding<String> {
        Binding(get: { viewModel.searchQuery.text },
                set: { viewModel.updateSearchText($0) })
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ForEach(viewModel.searchQuery.tokens) { token in
                SearchPill(token: token) { viewModel.removeToken(token) }
            }

            TextField(viewModel.searchQuery.tokens.isEmpty ? placeholder : "", text: textBinding)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
        )
        .overlay(alignment: .topLeading) {
            if viewModel.suggestionsVisible {
                SuggestionsDropdown(viewModel: viewModel)
                    .offset(y: 36)
            } else if focused && viewModel.searchQuery.text.isEmpty {
                // Discovery: what you can type. Informational only (no keyboard capture), so
                // ⏎ still pastes the selected card while this is showing.
                SearchHintPanel()
                    .offset(y: 36)
            }
        }
    }
}

/// Shown when the empty search field is focused: a compact legend of the filter categories
/// so users discover they can filter by app, type, time, favorites, and pinboards, not just
/// search text.
private struct SearchHintPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("SEARCH OR FILTER")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            row("textformat", "Type", "Text, Link, Image, File, Color")
            row("calendar", "Time", "Today, Last week, Last month…")
            row("star", "Favorites", "Only starred items")
            row("app.dashed", "App", "Name an app you copied from")
            row("pin", "Pinboard", "Name one of your boards")
        }
        .padding(11)
        .frame(width: 274, alignment: .leading)
        .background(DropdownBackdrop(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
    }

    private func row(_ icon: String, _ label: String, _ examples: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 62, alignment: .leading)
            Text(examples)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// A committed facet pill: app icon or SF Symbol, the label, and a hover-revealed ×.
private struct SearchPill: View {
    let token: SearchToken
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            TokenIcon(appBundleID: token.appBundleID, systemImage: token.systemImage, size: 12)
            Text(token.label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, hovering ? 5 : 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.7)))
        .onHover { hovering = $0 }
    }
}

/// The floating suggestions list. Rows accept on click; the keyboard-highlighted row (driven
/// by `AppCoordinator.onKeyEvent`) is filled with the accent color.
private struct SuggestionsDropdown: View {
    @Bindable var viewModel: ShelfViewModel

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(viewModel.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionRow(suggestion: suggestion, highlighted: index == viewModel.highlightedSuggestion)
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.acceptSuggestion(suggestion) }
                    .onHover { if $0 { viewModel.highlightedSuggestion = index } }
            }
        }
        .padding(4)
        .frame(width: 240, alignment: .leading)
        .background(DropdownBackdrop(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            TokenIcon(appBundleID: suggestion.appBundleID, systemImage: suggestion.systemImage,
                      size: 14, tint: highlighted ? .white : .secondary)
            Text(suggestion.label)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Color.accentColor : Color.clear)
        )
    }
}

/// The app icon for an app token/suggestion, or the SF Symbol for the other facets.
private struct TokenIcon: View {
    let appBundleID: String?
    let systemImage: String?
    var size: CGFloat = 12
    var tint: Color = .secondary

    var body: some View {
        if let appBundleID, let icon = AppIconCache.icon(forBundleID: appBundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.85))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }
}

/// The frosted backing of the search dropdowns (the hint panel and the suggestions list).
/// They float over the cards, so this blurs the shelf's own content beneath them. SwiftUI's
/// `Material` can't do that on macOS: it samples what is behind the window, so the panel
/// showed the desktop or another app through the shelf instead of the cards under it.
private struct DropdownBackdrop: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
    }
}
