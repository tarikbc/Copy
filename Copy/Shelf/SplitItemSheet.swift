import CopyCore
import SwiftUI

struct SplitItemSheet: View {
    let text: String
    let isLIFO: Bool
    let existingCount: Int
    let hideSecrets: Bool
    let onCancel: () -> Void
    let onAdd: ([String]) -> Void

    @State private var separator: TextSeparator
    @State private var customSeparator = ""
    @State private var regexPattern = ""
    @State private var removeDuplicates = false
    @State private var suggestion: TextSplitSuggestion?
    @State private var entries: [String]
    @State private var splitError: String?
    @State private var completedRequest: SplitRequest?

    private struct SplitRequest: Hashable, Sendable {
        let text: String
        let separator: TextSeparator
        let custom: String
        let pattern: String
    }

    private var request: SplitRequest {
        SplitRequest(text: text, separator: separator, custom: customSeparator, pattern: regexPattern)
    }

    private var usefulSuggestion: TextSplitSuggestion? {
        guard let suggestion,
              suggestion.separator != separator || (separator == .regex && suggestion.pattern != regexPattern)
        else { return nil }
        return suggestion
    }

    init(text: String, isLIFO: Bool, existingCount: Int, hideSecrets: Bool = false,
         onCancel: @escaping () -> Void, onAdd: @escaping ([String]) -> Void) {
        self.text = text
        self.isLIFO = isLIFO
        self.existingCount = existingCount
        self.hideSecrets = hideSecrets
        self.onCancel = onCancel
        self.onAdd = onAdd
        let initialSeparator = TextSplitter.suggestedSeparator(for: text) ?? .comma
        _separator = State(initialValue: initialSeparator)
        _entries = State(initialValue: TextSplitter.split(text, separator: initialSeparator))
        _completedRequest = State(initialValue: SplitRequest(text: text, separator: initialSeparator, custom: "", pattern: ""))
    }

    var body: some View {
        let request = request
        let isCurrent = completedRequest == request
        let duplicateCount = entries.count - Set(entries).count
        let output = filteredEntries
        let preview = isLIFO ? Array(output.reversed()) : output
        VStack(spacing: 0) {
            toolbar(entries: output, isCurrent: isCurrent)
            Divider()
            controls
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Divider()
            previewHeader(count: output.count, duplicateCount: duplicateCount, isCurrent: isCurrent)
            previewList(preview, isCurrent: isCurrent)
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
        .glassSurface(cornerRadius: 14)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: request) {
            guard completedRequest != request else { return }
            // Only a new separator requires matching. Duplicate removal filters the
            // completed result so its control stays visible after it is selected.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                TextSplitter.result(request.text, separator: request.separator, custom: request.custom,
                                    pattern: request.pattern)
            }.value
            guard !Task.isCancelled else { return }
            entries = result.entries
            splitError = result.error
            if Set(result.entries).count == result.entries.count { removeDuplicates = false }
            completedRequest = request
        }
        .task {
            let result = await SeparatorSuggestionService.suggest(for: text)
            guard !Task.isCancelled else { return }
            if case .suggestion(let value) = result { suggestion = value }
        }
    }

    private var filteredEntries: [String] {
        guard removeDuplicates else { return entries }
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }
    }

    private func toolbar(entries: [String], isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 8)
            Text("Split into Paste Stack")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Button("Add \(entries.count)") { onAdd(entries) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isCurrent || entries.isEmpty || splitError != nil)
                .accessibilityLabel("Add \(entries.count) entries to Paste Stack")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Split by")
                    .font(Tokens.cardSubtitle)
                Picker("Separator", selection: $separator) {
                    ForEach(TextSeparator.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .controlSize(.small)
                Spacer(minLength: 0)
                if let suggestion = usefulSuggestion {
                    Button {
                        regexPattern = suggestion.pattern
                        separator = suggestion.separator
                    } label: {
                        Label("Use \(suggestion.separator.title)", systemImage: "sparkles")
                            .font(Tokens.cardTitle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Apple Intelligence suggests this separator.")
                }
            }
            if separator == .custom {
                TextField("Separator text", text: $customSeparator)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Custom separator")
            }
            if separator == .regex {
                HStack(spacing: 8) {
                    TextField("Pattern, e.g. [,;\\s]+", text: $regexPattern)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Regex pattern")
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("Each match is a separator. Use (?i) for case-insensitive matching.")
                        .accessibilityLabel("Each regex match is a separator.")
                }
            }
            if let suggestion = usefulSuggestion, suggestion.separator == .regex {
                Text(suggestion.pattern)
                    .font(Tokens.bodyMono)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(suggestion.pattern)
            }
            if completedRequest == request, let splitError {
                Text(splitError)
                    .font(Tokens.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Regex error: \(splitError)")
            }
        }
    }

    private func previewHeader(count: Int, duplicateCount: Int, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            Text(isCurrent ? "\(count) \(count == 1 ? "entry" : "entries")" : "Preview")
                .font(Tokens.cardSubtitle)
                .monospacedDigit()
            if isCurrent, duplicateCount > 0 {
                Toggle("Remove duplicates", isOn: $removeDuplicates)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(Tokens.cardTitle)
                    .help("\(duplicateCount) repeated entries")
            }
            Spacer(minLength: 0)
            Text(isLIFO ? "Newest first" : "Oldest first")
                .font(Tokens.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func previewList(_ preview: [String], isCurrent: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isCurrent, preview.isEmpty {
                    Text(separator == .custom || separator == .regex
                         ? "Enter a separator to preview the entries." : "No entries to add.")
                        .font(Tokens.cardBody)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                }
                ForEach(Array(preview.prefix(200).enumerated()), id: \.offset) { index, entry in
                    let number = index + 1 + (isLIFO ? 0 : existingCount)
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(number)")
                            .font(Tokens.cardTitle)
                            .foregroundStyle(number == 1 ? Color.white : Color.secondary)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(number == 1 ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
                        Text(hideSecrets ? SecretDetector.masked(entry) : entry)
                            .font(Tokens.cardBody)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 3)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                if preview.count > 200 {
                    Text("\(preview.count - 200) more entries will also be added.")
                        .font(Tokens.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .opacity(isCurrent ? 1 : 0.45)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Paste Stack only")
                .help("Entries stay out of History. Spaces at the edges and empty entries are removed.")
            Spacer()
            if existingCount > 0 {
                Text("\(existingCount) already queued")
                    .monospacedDigit()
            }
        }
        .font(Tokens.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
