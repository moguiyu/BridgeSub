import SwiftUI

struct CueTableView: View {
    let cues: [BilingualCue]
    let subtitle1Label: String
    let subtitle2Label: String
    @Binding var editableCues: [BilingualCue]?
    var showsSourceDraftPlaceholders = false
    var showsTargetDraftPlaceholders = false
    var onLoadMore: (() -> Void)? = nil

    @State private var selectedCueID: Int?
    @State private var editingCue: BilingualCue?

    private var isEditable: Bool { editableCues != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cueHeader

            Divider()

            // Table
            if cues.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "text.line.spacing")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No cues available")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Load subtitles to see the cue table.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(cues) { cue in
                            CueRow(
                                cue: cue,
                                isSelected: selectedCueID == cue.id,
                                onSelect: { selectedCueID = cue.id },
                                showsSourceDraftPlaceholder: showsSourceDraftPlaceholders,
                                showsTargetDraftPlaceholder: showsTargetDraftPlaceholders,
                                onEdit: isEditable ? { editingCue = cue } : nil
                            )
                            Divider()
                        }
                        // Load more trigger at bottom
                        if onLoadMore != nil {
                            LoadMoreTrigger(onLoadMore: onLoadMore!)
                        }
                    }
                }
            }
        }
        .sheet(item: $editingCue) { cue in
            CueEditSheet(cue: cue) { newText in
                if let cues = editableCues, let idx = cues.firstIndex(where: { $0.id == cue.id }) {
                    editableCues?[idx] = BilingualCue(
                        id: cue.id,
                        startMilliseconds: cue.startMilliseconds,
                        endMilliseconds: cue.endMilliseconds,
                        sourceText: cue.sourceText,
                        targetText: newText,
                        alignmentConfidence: cue.alignmentConfidence,
                        alignmentStatus: cue.alignmentStatus
                    )
                }
            }
        }
    }

    private var cueHeader: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Text("Time")
                .frame(width: 70, alignment: .leading)

            Text(subtitle1Label)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(subtitle2Label)
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: 14, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

private struct CueRow: View {
    let cue: BilingualCue
    let isSelected: Bool
    let onSelect: () -> Void
    let showsSourceDraftPlaceholder: Bool
    let showsTargetDraftPlaceholder: Bool
    var onEdit: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(formatTime(cue.startMilliseconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            sourceTextView
                .frame(maxWidth: .infinity, alignment: .leading)

            targetTextView
                .frame(maxWidth: .infinity, alignment: .leading)

            statusIcon
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2) {
            onEdit?()
        }
    }

    private var targetTextColor: Color {
        if showsTargetDraftPlaceholder && cue.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .secondary.opacity(0.7)
        }
        switch cue.alignmentStatus {
        case .matched: return .primary
        case .lowConfidence: return .orange
        case .unmatched: return .secondary
        }
    }

    private var sourceTextView: some View {
        Group {
            if showsSourceDraftPlaceholder && cue.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Pending translation...")
                    .font(.system(.body, design: .default))
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                Text(cue.sourceText)
                    .font(.system(.body, design: .default))
            }
        }
    }

    private var targetTextView: some View {
        Group {
            if showsTargetDraftPlaceholder && cue.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Pending translation...")
                    .font(.system(.body, design: .default))
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                Text(cue.targetText)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(targetTextColor)
            }
        }
    }

    private var statusIcon: some View {
        Group {
            if (showsSourceDraftPlaceholder && cue.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                || (showsTargetDraftPlaceholder && cue.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Image(systemName: "hourglass")
                    .foregroundStyle(.tertiary)
            } else {
                switch cue.alignmentStatus {
                case .matched:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .lowConfidence:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .unmatched:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }

    private func formatTime(_ ms: Int) -> String {
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1_000
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

private struct CueEditSheet: View {
    let cue: BilingualCue
    let onCommit: (String) -> Void

    @State private var editText: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Target Text")
                .font(.headline)

            Text("Source: \(cue.sourceText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextEditor(text: $editText)
                .frame(minHeight: 100)
                .font(.body)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Save") {
                    onCommit(editText)
                    dismiss()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { editText = cue.targetText }
    }
}

private struct LoadMoreTrigger: View {
    let onLoadMore: () -> Void

    @State private var hasTriggered = false

    var body: some View {
        Color.clear
            .frame(height: 1)
            .onAppear {
                if !hasTriggered {
                    hasTriggered = true
                    onLoadMore()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        hasTriggered = false
                    }
                }
            }
    }
}
