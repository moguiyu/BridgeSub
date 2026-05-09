import AppKit
import SwiftUI

struct WorkflowInspectorView: View {
    @Bindable var viewModel: WorkflowViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioSpacing.lg) {
                header

                if let message = viewModel.previewStatusMessage {
                    infoBanner(message, systemImage: "sparkles")
                }

                previewSection
                cueFeedSection
                alignmentSection
                exportSection
            }
            .padding(StudioSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StudioColor.backgroundElevated)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: StudioSpacing.md) {
            VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: StudioSpacing.sm) {
                    Text("Inspector")
                        .font(StudioFont.paneTitle)
                        .foregroundStyle(StudioColor.text)

                    if let videoURL = viewModel.selectedVideoURL {
                        Text(videoURL.lastPathComponent)
                            .font(StudioFont.caption)
                            .foregroundStyle(StudioColor.textSecondary)
                            .lineLimit(1)
                    }
                }

                Text(headerSubtitle)
                    .font(StudioFont.caption)
                    .foregroundStyle(StudioColor.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: StudioSpacing.md)

            VStack(alignment: .trailing, spacing: StudioSpacing.xs) {
                StudioStatusTag(phaseLabel, tone: phaseTone, systemImage: phaseSymbol)

                if viewModel.hasPendingWorkflowWork {
                    StudioStatusTag("Working", tone: .accent, systemImage: "arrow.triangle.2.circlepath")
                }

                if viewModel.previewState.isDraftPreview {
                    StudioStatusTag("Draft Preview", tone: .warning, systemImage: "sparkles")
                }
            }
        }
    }

    private var headerSubtitle: String {
        if viewModel.selectedVideoURL == nil {
            return "Select a video, inspect the live preview, and check export readiness here."
        }
        if viewModel.previewState.displayedCues.isEmpty {
            return "The panel stays compact while cues, alignment, and export readiness resolve."
        }
        return "Live preview and export controls update as subtitle candidates settle."
    }

    private var phaseLabel: String {
        switch viewModel.phase {
        case .idle:
            return "Idle"
        case .videoSelected:
            return "Video Selected"
        case .inspected:
            return "Inspected"
        case .languagesChosen:
            return "Languages Chosen"
        case .candidatesResolved:
            return "Candidates Resolved"
        case .targetQualityChecked:
            return "Quality Checked"
        case .previewReady:
            return "Preview Ready"
        case .exportReady:
            return "Export Ready"
        }
    }

    private var phaseTone: StudioTagTone {
        switch viewModel.phase {
        case .idle, .videoSelected:
            return .neutral
        case .inspected, .languagesChosen, .candidatesResolved:
            return .info
        case .targetQualityChecked:
            return .warning
        case .previewReady, .exportReady:
            return .success
        }
    }

    private var phaseSymbol: String {
        switch viewModel.phase {
        case .idle:
            return "circle"
        case .videoSelected:
            return "film"
        case .inspected:
            return "checkmark.circle"
        case .languagesChosen:
            return "textformat"
        case .candidatesResolved:
            return "rectangle.stack.badge.checkmark"
        case .targetQualityChecked:
            return "checklist"
        case .previewReady:
            return "play.rectangle"
        case .exportReady:
            return "square.and.arrow.up"
        }
    }

    private var previewSection: some View {
        sectionCard(title: "Live Preview", systemImage: "play.rectangle.on.rectangle") {
            VStack(alignment: .leading, spacing: StudioSpacing.md) {
                previewFrame

                HStack(alignment: .top, spacing: StudioSpacing.sm) {
                    metricTile(
                        title: "\(viewModel.previewState.loadedCueCount)/\(max(viewModel.previewState.totalCueCount, viewModel.previewState.loadedCueCount))",
                        subtitle: "loaded cues",
                        tone: .accent,
                        systemImage: "text.bubble"
                    )

                    metricTile(
                        title: "\(viewModel.previewState.lowConfidenceCount)",
                        subtitle: "low confidence",
                        tone: viewModel.previewState.lowConfidenceCount > 0 ? .warning : .success,
                        systemImage: "exclamationmark.triangle"
                    )

                    metricTile(
                        title: viewModel.qualityScoreLabel,
                        subtitle: "quality score",
                        tone: qualityTone,
                        systemImage: "chart.line.uptrend.xyaxis"
                    )
                }

                Text(viewModel.alignmentSummaryLine)
                    .font(StudioFont.caption)
                    .foregroundStyle(StudioColor.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private var previewFrame: some View {
        let cue = viewModel.previewState.displayedCues.first
        let videoName = viewModel.selectedVideoURL?.lastPathComponent ?? "No video selected"

        return ZStack {
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(Color(red: 0.058, green: 0.067, blue: 0.083))

            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)

            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                HStack(alignment: .top, spacing: StudioSpacing.sm) {
                    VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                        Text(videoName)
                            .font(StudioFont.captionStrong)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(frameSubtitle)
                            .font(StudioFont.caption)
                            .foregroundStyle(Color.white.opacity(0.66))
                            .lineLimit(1)
                    }

                    Spacer(minLength: StudioSpacing.sm)

                    VStack(alignment: .trailing, spacing: StudioSpacing.xxs) {
                        StudioStatusTag(phaseLabel, tone: phaseTone, systemImage: phaseSymbol)

                        if viewModel.previewState.isBuildingFullMerge {
                            StudioStatusTag("Building merge", tone: .info, systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }

                Spacer(minLength: StudioSpacing.sm)

                if let cue {
                    VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                        Text(cue.sourceText.isEmpty ? "No source cue text" : cue.sourceText)
                            .font(StudioFont.bodyStrong)
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Text(cue.targetText.isEmpty ? "No target cue text" : cue.targetText)
                            .font(StudioFont.body)
                            .foregroundStyle(Color.white.opacity(0.84))
                            .lineLimit(2)
                    }
                    .padding(StudioSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.24))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
                } else {
                    emptyPreviewPrompt
                }

                HStack(alignment: .firstTextBaseline, spacing: StudioSpacing.sm) {
                    Text(cueTimeLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.72))

                    Spacer(minLength: StudioSpacing.sm)

                    StudioStatusTag(
                        previewStatusLabel,
                        tone: previewStatusTone,
                        systemImage: previewStatusSymbol
                    )
                }
            }
            .padding(StudioSpacing.md)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    private var frameSubtitle: String {
        if viewModel.previewState.displayedCues.isEmpty {
            return "Waiting for subtitle cues"
        }
        if viewModel.previewState.isDraftPreview {
            return "Draft captions from the current merge"
        }
        return "Merged captions from the active selection"
    }

    private var cueTimeLabel: String {
        guard let cue = viewModel.previewState.displayedCues.first else {
            return "--:--:--"
        }
        return timecode(for: cue.startMilliseconds)
    }

    private var previewStatusLabel: String {
        if viewModel.previewState.displayedCues.isEmpty {
            return "No cues"
        }
        if viewModel.previewState.isDraftPreview {
            return "Draft"
        }
        if viewModel.previewState.isBuildingFullMerge {
            return "Merging"
        }
        return "Live"
    }

    private var previewStatusTone: StudioTagTone {
        if viewModel.previewState.displayedCues.isEmpty {
            return .neutral
        }
        if viewModel.previewState.isBuildingFullMerge {
            return .info
        }
        if viewModel.previewState.isDraftPreview {
            return .warning
        }
        return .success
    }

    private var previewStatusSymbol: String {
        if viewModel.previewState.displayedCues.isEmpty {
            return "minus.circle"
        }
        if viewModel.previewState.isBuildingFullMerge {
            return "arrow.triangle.2.circlepath"
        }
        if viewModel.previewState.isDraftPreview {
            return "sparkles"
        }
        return "checkmark.circle"
    }

    private var emptyPreviewPrompt: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
            Text("No preview cues yet")
                .font(StudioFont.bodyStrong)
                .foregroundStyle(.white)

            Text("Choose subtitle candidates or start translation to populate the frame.")
                .font(StudioFont.caption)
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(StudioSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.24))
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
    }

    private var cueFeedSection: some View {
        sectionCard(title: "Cue Feed", systemImage: "text.bubble") {
            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                if viewModel.previewState.displayedCues.isEmpty {
                    emptyState(
                        title: "No cues loaded",
                        subtitle: "The inspector will populate once a merge, draft preview, or translation produces cue rows."
                    )
                } else {
                    LazyVStack(spacing: StudioSpacing.xs) {
                        ForEach(viewModel.previewState.displayedCues) { cue in
                            WorkflowInspectorCueRow(cue: cue)
                        }
                    }
                }

                if viewModel.previewState.hasMoreCues {
                    Button {
                        viewModel.loadMoreCues()
                    } label: {
                        Label(
                            "Load more cues (\(viewModel.previewState.loadedCueCount)/\(viewModel.previewState.totalCueCount))",
                            systemImage: "chevron.down"
                        )
                    }
                    .buttonStyle(StudioCompactButtonStyle())
                }
            }
        }
    }

    private var alignmentSection: some View {
        sectionCard(title: "Alignment", systemImage: "arrow.left.arrow.right") {
            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                if let report = viewModel.qualityReport {
                    HStack(alignment: .firstTextBaseline, spacing: StudioSpacing.sm) {
                        StudioStatusTag(
                            qualityDecisionTitle(report.decision),
                            tone: qualityDecisionTone,
                            systemImage: qualityDecisionSymbol
                        )

                        Text(viewModel.qualityScoreLabel)
                            .font(StudioFont.sectionHeader)
                            .foregroundStyle(StudioColor.text)

                        Spacer(minLength: StudioSpacing.md)

                        Text(viewModel.qualityStatusMessage ?? viewModel.alignmentSummaryLine)
                            .font(StudioFont.caption)
                            .foregroundStyle(StudioColor.textSecondary)
                            .lineLimit(2)
                    }

                    VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                        alignmentRow(
                            title: "Matched cues",
                            value: percentString(report.alignmentReport.matchedCueRatio),
                            systemImage: "checkmark.circle",
                            tone: .success
                        )

                        alignmentRow(
                            title: "Low confidence",
                            value: percentString(report.alignmentReport.lowConfidenceCueRatio),
                            systemImage: "exclamationmark.triangle",
                            tone: report.alignmentReport.lowConfidenceCueRatio > 0 ? .warning : .success
                        )

                        alignmentRow(
                            title: "Median drift",
                            value: millisecondsString(report.alignmentReport.medianStartDeltaMilliseconds),
                            systemImage: "clock",
                            tone: report.alignmentReport.medianStartDeltaMilliseconds > 250 ? .warning : .info
                        )

                        alignmentRow(
                            title: "Monotonicity",
                            value: "\(report.alignmentReport.monotonicityViolations)",
                            systemImage: "arrow.up.arrow.down",
                            tone: report.alignmentReport.monotonicityViolations > 0 ? .warning : .success
                        )

                        alignmentRow(
                            title: "Average confidence",
                            value: percentString(report.alignmentReport.averageConfidence),
                            systemImage: "chart.bar",
                            tone: averageConfidenceTone(report.alignmentReport.averageConfidence)
                        )
                    }

                    if let reminder = viewModel.qualityReminderMessage {
                        infoBanner(reminder, systemImage: "exclamationmark.triangle")
                    }

                    if !report.notes.isEmpty {
                        VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                            ForEach(report.notes.prefix(3), id: \.self) { note in
                                noteRow(note)
                            }
                        }
                    }
                } else if viewModel.isQualityEvaluationPending {
                    pendingState(
                        title: "Quality check running",
                        subtitle: "The alignment report will fill in as soon as evaluation finishes."
                    )
                } else {
                    emptyState(
                        title: "Alignment metrics unavailable",
                        subtitle: "Merge two subtitle tracks to surface timing drift, confidence, and quality data."
                    )
                }

                // ── VAD Voice Analysis ───────────────────────────

                if viewModel.isVADAnalysisRunning {
                    HStack(spacing: StudioSpacing.sm) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                        Text("Analyzing audio with voice detection...")
                            .font(StudioFont.caption)
                            .foregroundStyle(StudioColor.textSecondary)
                    }
                    .padding(.top, StudioSpacing.sm)
                }

                if viewModel.vadHasResult, let result = viewModel.lastVADResult {
                    VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                        HStack(spacing: StudioSpacing.sm) {
                            Image(systemName: "waveform")
                                .foregroundStyle(StudioColor.accent)
                            Text("Voice Analysis")
                                .font(StudioFont.captionStrong)
                                .foregroundStyle(StudioColor.text)
                            Spacer()
                            Text(viewModel.vadElapsedLabel ?? "")
                                .font(StudioFont.caption)
                                .foregroundStyle(StudioColor.textSecondary)
                        }

                        alignmentRow(
                            title: "Card 1 (source)",
                            value: viewModel.vadSourceScoreLabel,
                            systemImage: "1.circle",
                            tone: result.sourceAverageScore > result.targetAverageScore ? .success : .neutral
                        )
                        alignmentRow(
                            title: "Card 2 (target)",
                            value: viewModel.vadTargetScoreLabel,
                            systemImage: "2.circle",
                            tone: result.targetAverageScore > result.sourceAverageScore ? .success : .neutral
                        )
                        alignmentRow(
                            title: "Master timeline",
                            value: viewModel.vadMasterSideLabel ?? "—",
                            systemImage: "crown",
                            tone: .info
                        )
                        alignmentRow(
                            title: "Speech segments",
                            value: "\(viewModel.vadSpeechSegmentCount)",
                            systemImage: "bubble.left.and.bubble.right",
                            tone: viewModel.vadSpeechSegmentCount > 0 ? .success : .warning
                        )
                    }
                    .padding(.top, StudioSpacing.sm)
                    .padding(.horizontal, StudioSpacing.xs)

                    Divider()
                        .padding(.vertical, 2)
                }

                if viewModel.showVADReminder {
                    VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                        infoBanner(
                            "Alignment confidence is low. Analyze the audio track with voice detection to improve timeline matching.",
                            systemImage: "waveform.badge.exclamationmark"
                        )
                        Button {
                            Task { await viewModel.analyzeWithVADAndRerunMerge() }
                        } label: {
                            Label("Analyze with Voice", systemImage: "waveform")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.top, StudioSpacing.sm)
                }

                if !viewModel.vadHasResult && !viewModel.isVADAnalysisRunning && !viewModel.showVADReminder,
                   !viewModel.availableAudioTracks.isEmpty {
                    HStack(spacing: StudioSpacing.sm) {
                        Picker("Audio track", selection: $viewModel.selectedAudioTrackIndex) {
                            ForEach(viewModel.availableAudioTracks) { track in
                                Text(track.displayLabel).tag(track.index)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(StudioFont.caption)

                        Button {
                            Task { await viewModel.analyzeWithVADAndRerunMerge() }
                        } label: {
                            Label("Analyze", systemImage: "waveform")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, StudioSpacing.sm)
                }
            }
        }
    }

    private var exportSection: some View {
        sectionCard(title: "Export", systemImage: "square.and.arrow.up") {
            VStack(alignment: .leading, spacing: StudioSpacing.md) {
                HStack(alignment: .center, spacing: StudioSpacing.sm) {
                    Text("Format")
                        .font(StudioFont.captionStrong)
                        .foregroundStyle(StudioColor.textSecondary)

                    Picker("", selection: $viewModel.exportFormat) {
                        Text("SRT").tag(SubtitleFormatKind.srt)
                        Text("ASS").tag(SubtitleFormatKind.ass)
                        Text("VTT").tag(SubtitleFormatKind.vtt)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: viewModel.exportFormat) {
                        viewModel.exportFormatChanged()
                    }

                    Spacer(minLength: StudioSpacing.md)
                }

                readinessRow(
                    title: "Sidecar export",
                    subtitle: viewModel.canSaveSidecar ? "Ready to save a local subtitle file" : "Merge subtitles before saving",
                    status: viewModel.canSaveSidecar ? "Ready" : "Blocked",
                    tone: viewModel.canSaveSidecar ? .success : .neutral,
                    systemImage: viewModel.canSaveSidecar ? "checkmark.circle" : "minus.circle"
                )

                ProgressButton(
                    "Save Sidecar",
                    isLoading: viewModel.isProcessing,
                    isCompact: true
                ) {
                    viewModel.saveSidecar()
                } label: {
                    Label("Save Sidecar", systemImage: "square.and.arrow.down")
                }
                .disabled(!viewModel.canSaveSidecar)
                .frame(maxWidth: .infinity, alignment: .leading)

                readinessRow(
                    title: "Embed into video",
                    subtitle: viewModel.embedStatusMessage ?? (viewModel.canEmbedIntoVideo ? "Ready to write the subtitle stream into the container" : "No container support available for the current selection"),
                    status: viewModel.canEmbedIntoVideo ? "Ready" : "Blocked",
                    tone: viewModel.canEmbedIntoVideo ? .success : .neutral,
                    systemImage: viewModel.canEmbedIntoVideo ? "checkmark.circle" : "minus.circle"
                )

                HStack(alignment: .center, spacing: StudioSpacing.sm) {
                    Text("Destination")
                        .font(StudioFont.captionStrong)
                        .foregroundStyle(StudioColor.textSecondary)

                    Picker("", selection: $viewModel.embedDestinationMode) {
                        Text("Create new file").tag(EmbedDestinationMode.createNewFile)
                        Text("Replace original").tag(EmbedDestinationMode.replaceOriginal)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Spacer(minLength: StudioSpacing.md)
                }

                ProgressButton(
                    viewModel.embedActionTitle,
                    isLoading: viewModel.isProcessing,
                    isCompact: true
                ) {
                    Task { await viewModel.embedIntoVideo() }
                } label: {
                    Label(viewModel.embedActionTitle, systemImage: "film")
                }
                .disabled(!viewModel.canEmbedIntoVideo)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    Text("Recent Output")
                        .font(StudioFont.captionStrong)
                        .foregroundStyle(StudioColor.textSecondary)

                    outputRow(
                        title: "Sidecar",
                        value: viewModel.lastSavedSidecarURL?.lastPathComponent ?? viewModel.defaultSidecarName
                    )

                    outputRow(
                        title: "Embedded",
                        value: viewModel.lastEmbeddedOutputURL?.lastPathComponent ?? "No embedded output yet"
                    )
                }
            }
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            HStack(spacing: StudioSpacing.sm) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioColor.textSecondary)

                Text(title)
                    .font(StudioFont.sectionHeader)
                    .foregroundStyle(StudioColor.text)

                Spacer(minLength: StudioSpacing.md)
            }

            content()
        }
        .studioSubtleSurface(cornerRadius: StudioRadius.xl, padding: StudioSpacing.md)
    }

    private func metricTile(title: String, subtitle: String, tone: StudioTagTone, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: StudioSpacing.xs) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .font(StudioFont.bodyStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tone.foreground)

            Text(subtitle)
                .font(StudioFont.caption)
                .foregroundStyle(StudioColor.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, StudioSpacing.sm)
        .padding(.vertical, StudioSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .stroke(tone.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
    }

    private func alignmentRow(title: String, value: String, systemImage: String, tone: StudioTagTone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: StudioSpacing.sm) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone.foreground)

            Text(title)
                .font(StudioFont.captionStrong)
                .foregroundStyle(StudioColor.text)

            Spacer(minLength: StudioSpacing.md)

            Text(value)
                .font(StudioFont.caption)
                .foregroundStyle(StudioColor.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, StudioSpacing.sm)
        .padding(.vertical, StudioSpacing.xs)
        .background(StudioColor.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .stroke(StudioColor.border.opacity(0.75), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
    }

    private func readinessRow(title: String, subtitle: String, status: String, tone: StudioTagTone, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: StudioSpacing.sm) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone.foreground)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                Text(title)
                    .font(StudioFont.captionStrong)
                    .foregroundStyle(StudioColor.text)

                Text(subtitle)
                    .font(StudioFont.caption)
                    .foregroundStyle(StudioColor.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: StudioSpacing.md)

            StudioStatusTag(status, tone: tone, systemImage: systemImage)
        }
    }

    private func outputRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: StudioSpacing.sm) {
            Text(title)
                .font(StudioFont.captionStrong)
                .foregroundStyle(StudioColor.textSecondary)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .font(StudioFont.caption)
                .foregroundStyle(StudioColor.text)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }

    private func noteRow(_ note: String) -> some View {
        HStack(alignment: .top, spacing: StudioSpacing.sm) {
            Image(systemName: "dot.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioColor.textSecondary)
                .padding(.top, 2)

            Text(note)
                .font(StudioFont.caption)
                .foregroundStyle(StudioColor.textSecondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, StudioSpacing.sm)
        .padding(.vertical, StudioSpacing.xs)
        .background(StudioColor.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .stroke(StudioColor.border.opacity(0.75), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
    }

    private func infoBanner(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: StudioSpacing.sm) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioColor.textSecondary)
                .padding(.top, 1)

            Text(text)
                .font(StudioFont.caption)
                .foregroundStyle(StudioColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(StudioSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColor.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .stroke(StudioColor.border.opacity(0.75), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
            Text(title)
                .font(StudioFont.captionStrong)
                .foregroundStyle(StudioColor.text)

            Text(subtitle)
                .font(StudioFont.caption)
                .foregroundStyle(StudioColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(StudioSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColor.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .stroke(StudioColor.border.opacity(0.75), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
    }

    private func pendingState(title: String, subtitle: String) -> some View {
        emptyState(title: title, subtitle: subtitle)
    }

    private func qualityDecisionTitle(_ decision: SubtitleDecision) -> String {
        switch decision {
        case .accept:
            return "Accept"
        case .review:
            return "Review"
        case .reject:
            return "Reject"
        }
    }

    private var qualityDecisionTone: StudioTagTone {
        guard let decision = viewModel.qualityReport?.decision else { return .neutral }
        switch decision {
        case .accept:
            return .success
        case .review:
            return .warning
        case .reject:
            return .danger
        }
    }

    private var qualityDecisionSymbol: String {
        guard let decision = viewModel.qualityReport?.decision else { return "questionmark.circle" }
        switch decision {
        case .accept:
            return "checkmark.circle"
        case .review:
            return "exclamationmark.triangle"
        case .reject:
            return "xmark.circle"
        }
    }

    private var qualityTone: StudioTagTone {
        guard let decision = viewModel.qualityReport?.decision else { return .neutral }
        switch decision {
        case .accept:
            return .success
        case .review:
            return .warning
        case .reject:
            return .danger
        }
    }

    private func averageConfidenceTone(_ value: Double) -> StudioTagTone {
        if value >= 0.75 {
            return .success
        }
        if value >= 0.55 {
            return .warning
        }
        return .danger
    }

    private func percentString(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private func millisecondsString(_ value: Double) -> String {
        "\(Int(value.rounded())) ms"
    }

    private func timecode(for milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

private struct WorkflowInspectorCueRow: View {
    let cue: BilingualCue

    var body: some View {
        HStack(alignment: .top, spacing: StudioSpacing.sm) {
            Text(timeLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioColor.textSecondary)
                .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                Text(cue.sourceText.isEmpty ? " " : cue.sourceText)
                    .font(StudioFont.caption)
                    .foregroundStyle(StudioColor.text)
                    .lineLimit(1)

                Text(cue.targetText.isEmpty ? " " : cue.targetText)
                    .font(StudioFont.caption)
                    .foregroundStyle(targetColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StudioStatusTag(statusLabel, tone: statusTone, systemImage: statusSymbol)
        }
        .padding(StudioSpacing.sm)
        .background(StudioColor.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .stroke(StudioColor.border.opacity(0.75), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
    }

    private var timeLabel: String {
        let totalSeconds = cue.startMilliseconds / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private var targetColor: Color {
        switch cue.alignmentStatus {
        case .matched:
            return StudioColor.text
        case .lowConfidence:
            return StudioColor.warning
        case .unmatched:
            return StudioColor.textSecondary
        }
    }

    private var statusLabel: String {
        switch cue.alignmentStatus {
        case .matched:
            return "Match"
        case .lowConfidence:
            return "Low"
        case .unmatched:
            return "Miss"
        }
    }

    private var statusTone: StudioTagTone {
        switch cue.alignmentStatus {
        case .matched:
            return .success
        case .lowConfidence:
            return .warning
        case .unmatched:
            return .neutral
        }
    }

    private var statusSymbol: String {
        switch cue.alignmentStatus {
        case .matched:
            return "checkmark.circle.fill"
        case .lowConfidence:
            return "exclamationmark.triangle.fill"
        case .unmatched:
            return "xmark.circle.fill"
        }
    }
}
