import SwiftUI

struct WorkflowSidebarView: View {
    @Bindable var viewModel: WorkflowViewModel
    @Binding var activeCardIndex: Int

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    JobSummary(
                        viewModel: viewModel,
                        activeCardIndex: activeCardIndex
                    )

                    WorkflowStepList(
                        viewModel: viewModel,
                        activeCardIndex: $activeCardIndex
                    )

                    RiskHintList(viewModel: viewModel, activeCardIndex: activeCardIndex)

                    LatestLogSummary(viewModel: viewModel)
                }
                .padding(StudioSpacing.lg)
            }
        }
        .background(StudioColor.background)
    }
}

private struct JobSummary: View {
    @Bindable var viewModel: WorkflowViewModel
    let activeCardIndex: Int

    var body: some View {
        SidebarSection(title: "Job Summary", systemImage: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: StudioSpacing.md) {
                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    Text(jobTitle)
                        .font(StudioFont.sectionHeader)
                        .foregroundStyle(StudioColor.text)
                        .lineLimit(2)

                    Text(jobSubtitle)
                        .font(StudioFont.caption)
                        .foregroundStyle(StudioColor.textSecondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    StatusBadge(label: phaseLabel, state: phaseState)
                }

                HStack(spacing: 8) {
                    MetricPill(label: "Audio", value: audioCountText)
                    MetricPill(label: "Subtitles", value: subtitleCountText)
                    MetricPill(label: "Sidecars", value: sidecarCountText)
                }

                if viewModel.hasPendingWorkflowWork {
                    Label(workflowActivityLabel, systemImage: "arrow.triangle.2.circlepath")
                        .font(StudioFont.caption)
                        .foregroundStyle(StudioColor.textSecondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var jobTitle: String {
        viewModel.selectedVideoURL?.lastPathComponent ?? "No video selected"
    }

    private var jobSubtitle: String {
        guard let inspection = viewModel.inspectionReport else {
            return "Inspect the video to surface subtitle tracks, audio streams, and local sidecars."
        }

        let subtitleCount = inspection.embeddedSubtitleTracks.filter { $0.isTextBased }.count
        let audioCount = inspection.audioStreams.count
        let sidecarCount = inspection.localSubtitleSidecars.count
        return "\(inspection.containerName) · \(audioCount) audio · \(subtitleCount) subtitle tracks · \(sidecarCount) sidecars"
    }

    private var audioCountText: String {
        viewModel.inspectionReport.map { "\($0.audioStreams.count)" } ?? "0"
    }

    private var subtitleCountText: String {
        guard let inspection = viewModel.inspectionReport else { return "0" }
        return "\(inspection.embeddedSubtitleTracks.filter { $0.isTextBased }.count)"
    }

    private var sidecarCountText: String {
        viewModel.inspectionReport.map { "\($0.localSubtitleSidecars.count)" } ?? "0"
    }

    private var workflowActivityLabel: String {
        if viewModel.isProcessing, !viewModel.processingLabel.isEmpty {
            return viewModel.processingLabel
        }
        if viewModel.hasActiveTranslation, let cardIndex = activeCardIndexIfValid {
            return viewModel.translationProgressLabel(forCardIndex: cardIndex)
        }
        if viewModel.isResolvingSelection {
            return "Resolving subtitle selections..."
        }
        if viewModel.previewStatusMessage != nil {
            return viewModel.previewStatusMessage ?? ""
        }
        return "Workflow is idle."
    }

    private var phaseLabel: String {
        switch viewModel.phase {
        case .idle: return "Idle"
        case .videoSelected: return "Video selected"
        case .inspected: return "Inspected"
        case .languagesChosen: return "Languages chosen"
        case .candidatesResolved: return "Candidates resolved"
        case .targetQualityChecked: return "Quality checked"
        case .previewReady: return "Preview ready"
        case .exportReady: return "Export ready"
        }
    }

    private var phaseState: WorkflowStepState {
        switch viewModel.phase {
        case .idle:
            return .upcoming
        case .videoSelected:
            return viewModel.inspectionReport == nil ? .current : .done
        case .inspected, .languagesChosen, .candidatesResolved:
            return .current
        case .targetQualityChecked, .previewReady, .exportReady:
            return .done
        }
    }

    private var activeCardIndexIfValid: Int? {
        viewModel.cards.indices.contains(activeCardIndex) ? activeCardIndex : nil
    }
}

private struct WorkflowStepList: View {
    @Bindable var viewModel: WorkflowViewModel
    @Binding var activeCardIndex: Int

    var body: some View {
        SidebarSection(title: "Workflow Steps", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(workflowSteps) { step in
                    stepRow(step)
                }
            }
        }
    }

    private var workflowSteps: [WorkflowStep] {
        var steps: [WorkflowStep] = [
            WorkflowStep(
                title: "Select video",
                detail: viewModel.selectedVideoURL?.lastPathComponent ?? "Choose a local file to inspect",
                state: viewModel.selectedVideoURL == nil ? .current : .done
            ),
            WorkflowStep(
                title: "Inspect media",
                detail: inspectionDetail,
                state: inspectionState
            ),
            WorkflowStep(
                title: "Subtitle A",
                detail: cardDetail(for: 0),
                state: cardState(for: 0),
                focusCardIndex: 0
            ),
            WorkflowStep(
                title: "Subtitle B",
                detail: cardDetail(for: 1),
                state: cardState(for: 1),
                focusCardIndex: 1
            )
        ]

        if let alignStep = alignAndSyncStep() {
            steps.append(alignStep)
        }

        steps.append(contentsOf: [
            WorkflowStep(
                title: "Quality gate",
                detail: viewModel.qualityStatusMessage ?? "Quality check runs after both cards resolve.",
                state: qualityState
            ),
            WorkflowStep(
                title: "Merged preview",
                detail: viewModel.previewStatusMessage ?? viewModel.previewPlaceholderMessage,
                state: previewState
            ),
            WorkflowStep(
                title: "Export",
                detail: exportDetail,
                state: exportState
            )
        ])
        return steps
    }

    private func alignAndSyncStep() -> WorkflowStep? {
        guard !viewModel.cards.isEmpty else { return nil }
        let cardsWithAnyReference = viewModel.cards.indices.filter { index in
            viewModel.cards[index].translateState.referenceCandidateID != nil
                || viewModel.cards[index].translateState.secondaryReferenceCandidateID != nil
        }
        guard let firstCardIndex = cardsWithAnyReference.first else { return nil }

        let state = viewModel.preAlignmentState(forCardIndex: firstCardIndex)
        let summary = viewModel.preAlignmentSummary(forCardIndex: firstCardIndex)
        let stepState: WorkflowStepState
        let detail: String
        switch state {
        case .idle:
            stepState = .upcoming
            detail = summary.isEmpty
                ? "Add a secondary reference to align it with the primary."
                : summary
        case .running:
            stepState = .current
            detail = summary.isEmpty ? "Aligning subtitles…" : summary
        case .completed:
            stepState = .done
            detail = summary.isEmpty ? "Alignment ready." : summary
        case .failed(let message):
            stepState = .warning
            detail = message
        }
        return WorkflowStep(
            title: "Align & Sync",
            detail: detail,
            state: stepState,
            focusCardIndex: firstCardIndex
        )
    }

    private var inspectionDetail: String {
        guard let inspection = viewModel.inspectionReport else {
            return viewModel.selectedVideoURL == nil ? "Waiting for a video" : "Inspection is running or pending."
        }

        let subtitleCount = inspection.embeddedSubtitleTracks.filter { $0.isTextBased }.count
        return "\(inspection.audioStreams.count) audio · \(subtitleCount) text subtitles · \(inspection.localSubtitleSidecars.count) sidecars"
    }

    private var inspectionState: WorkflowStepState {
        if viewModel.inspectionReport != nil {
            return .done
        }
        if viewModel.selectedVideoURL != nil {
            return viewModel.isProcessing ? .current : .current
        }
        return .upcoming
    }

    private func cardDetail(for index: Int) -> String {
        guard viewModel.cards.indices.contains(index) else { return "Unavailable" }

        let selection = viewModel.selectionSummary(forCardIndex: index)
        let language = viewModel.cards[index].language.displayName
        let activeTranslation = viewModel.cards[index].translateState.statusMessage
        if !activeTranslation.isEmpty {
            return "\(language) · \(selection) · \(activeTranslation)"
        }
        return "\(language) · \(selection)"
    }

    private func cardState(for index: Int) -> WorkflowStepState {
        guard viewModel.cards.indices.contains(index) else { return .upcoming }

        let card = viewModel.cards[index]
        if viewModel.hasActiveTranslation && activeCardIndex == index {
            return .current
        }
        if card.selectedCandidateID != nil {
            if viewModel.embeddedExtractionWarning(forCardIndex: index) != nil {
                return .warning
            }
            return .done
        }
        if viewModel.selectedVideoURL != nil {
            return activeCardIndex == index ? .current : .upcoming
        }
        return .upcoming
    }

    private var qualityState: WorkflowStepState {
        if viewModel.isQualityEvaluationPending {
            return .current
        }
        if viewModel.qualityReport != nil {
            return .done
        }
        if viewModel.canMerge {
            return viewModel.qualityReminderMessage == nil ? .current : .warning
        }
        return .upcoming
    }

    private var previewState: WorkflowStepState {
        if viewModel.previewState.isBuildingFullMerge {
            return .current
        }
        if viewModel.previewMode != .none {
            return .done
        }
        if viewModel.canMerge {
            return .current
        }
        return .upcoming
    }

    private var exportDetail: String {
        if let lastSaved = viewModel.lastSavedSidecarURL {
            return "Sidecar saved as \(lastSaved.lastPathComponent)"
        }
        if let lastEmbedded = viewModel.lastEmbeddedOutputURL {
            return "Embedded output written to \(lastEmbedded.lastPathComponent)"
        }
        if viewModel.canSaveSidecar {
            return viewModel.defaultSidecarName
        }
        return "Export becomes available after merge"
    }

    private var exportState: WorkflowStepState {
        if viewModel.lastSavedSidecarURL != nil || viewModel.lastEmbeddedOutputURL != nil {
            return .done
        }
        if viewModel.canSaveSidecar || viewModel.canEmbedIntoVideo {
            return .current
        }
        return .upcoming
    }

    private func stepRow(_ step: WorkflowStep) -> some View {
        let isFocusedCard = step.focusCardIndex == activeCardIndex
        let backgroundOpacity: Double = {
            switch step.state {
            case .current: return 0.12
            case .warning: return 0.10
            case .done, .upcoming: return 0.0
            }
        }()

        return Button {
            if let focusCardIndex = step.focusCardIndex {
                activeCardIndex = focusCardIndex
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: step.state.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(step.state.tint)
                    .frame(width: 16)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(step.title)
                            .font(StudioFont.bodyStrong)
                            .foregroundStyle(StudioColor.text)
                        if step.focusCardIndex != nil {
                            Text(step.state.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(step.state.tint)
                                .textCase(.uppercase)
                        }
                    }

                    Text(step.detail)
                        .font(StudioFont.caption)
                        .foregroundStyle(StudioColor.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if step.focusCardIndex != nil {
                    Image(systemName: isFocusedCard ? "chevron.right.circle.fill" : "chevron.right.circle")
                        .font(.caption)
                        .foregroundStyle(isFocusedCard ? StudioColor.accent : StudioColor.textSecondary)
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(step.state.tint.opacity(backgroundOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(step.state.tint.opacity(isFocusedCard ? 0.36 : 0.18), lineWidth: isFocusedCard ? 1.2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(step.focusCardIndex == nil)
    }
}

private struct RiskHintList: View {
    @Bindable var viewModel: WorkflowViewModel
    let activeCardIndex: Int

    var body: some View {
        SidebarSection(title: "Risk Hints", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                if hints.isEmpty {
                    Text("No active risks.")
                        .font(StudioFont.caption)
                        .foregroundStyle(StudioColor.textSecondary)
                } else {
                    ForEach(hints, id: \.self) { hint in
                        Label(hint, systemImage: "exclamationmark.triangle.fill")
                            .font(StudioFont.caption)
                            .foregroundStyle(StudioColor.textSecondary)
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var hints: [String] {
        var values: [String] = []

        if let message = viewModel.lastError, !message.isEmpty {
            values.append(message)
        }

        if let qualityReminder = viewModel.qualityReminderMessage {
            values.append(qualityReminder)
        }

        if let extractionWarning = viewModel.embeddedExtractionWarning(forCardIndex: activeCardIndex) {
            values.append(extractionWarning)
        }

        if !viewModel.bitmapOnlyLanguageLabels.isEmpty {
            values.append("OCR-only candidates: \(viewModel.bitmapOnlyLanguageLabels.joined(separator: ", "))")
        }

        if let embedStatus = viewModel.embedStatusMessage, !embedStatus.isEmpty {
            values.append(embedStatus)
        }

        return values.prefix(4).map { $0 }
    }
}

private struct LatestLogSummary: View {
    @Bindable var viewModel: WorkflowViewModel

    var body: some View {
        SidebarSection(title: "Latest Log", systemImage: "text.quote") {
            if let entry = viewModel.statusLines.first {
                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: entry.kind == .error ? "xmark.circle.fill" : "info.circle.fill")
                            .foregroundStyle(entry.kind == .error ? StudioColor.danger : StudioColor.textSecondary)
                        Text(entry.message)
                            .font(StudioFont.caption)
                            .foregroundStyle(entry.kind == .error ? StudioColor.danger : StudioColor.text)
                            .lineLimit(3)
                    }

                    Text(logTimestamp(entry.createdAt))
                        .font(StudioFont.caption)
                        .foregroundStyle(StudioColor.textSecondary)
                }
            } else {
                Text("No workflow log entries yet.")
                    .font(StudioFont.caption)
                    .foregroundStyle(StudioColor.textSecondary)
            }
        }
    }

    private func logTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct SidebarSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.sm) {
            HStack(spacing: StudioSpacing.sm) {
                Label(title, systemImage: systemImage)
                    .font(StudioFont.sectionHeader)
                    .foregroundStyle(StudioColor.text)
                Spacer(minLength: 0)
            }

            content
        }
        .padding(StudioSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(StudioColor.surfaceSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .strokeBorder(StudioColor.border, lineWidth: 1)
        )
    }
}

private struct StatusBadge: View {
    let label: String
    let state: WorkflowStepState

    var body: some View {
        Label(label, systemImage: state.symbolName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(state.tint.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(state.tint.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StudioFont.caption)
                .foregroundStyle(StudioColor.textSecondary)
            Text(value)
                .font(StudioFont.captionStrong)
                .foregroundStyle(StudioColor.text)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(StudioColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StudioColor.border, lineWidth: 1)
        )
    }
}

private struct WorkflowStep: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let state: WorkflowStepState
    let focusCardIndex: Int?

    init(title: String, detail: String, state: WorkflowStepState, focusCardIndex: Int? = nil) {
        self.title = title
        self.detail = detail
        self.state = state
        self.focusCardIndex = focusCardIndex
    }
}

private enum WorkflowStepState {
    case done
    case current
    case upcoming
    case warning

    var symbolName: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .current: return "circle.inset.filled"
        case .upcoming: return "circle"
        case .warning: return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .done: return StudioColor.success
        case .current: return StudioColor.accent
        case .upcoming: return StudioColor.textSecondary
        case .warning: return StudioColor.warning
        }
    }

    var label: String {
        switch self {
        case .done: return "Done"
        case .current: return "Current"
        case .upcoming: return "Next"
        case .warning: return "Risk"
        }
    }
}
