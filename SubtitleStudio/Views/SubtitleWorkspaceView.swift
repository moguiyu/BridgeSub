import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SubtitleWorkspaceView: View {
    let cardIndex: Int
    @Bindable var viewModel: WorkflowViewModel
    @State private var showingCancelConfirmation = false

    private let topAnchorID = "workspace-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: StudioSpacing.lg) {
                    Color.clear
                        .frame(height: 1)
                        .id(topAnchorID)

                    languageSection
                    sourceModeCards
                    contentPanel
                }
                .padding(StudioSpacing.lg)
                .padding(.bottom, StudioSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: viewModel.cards[cardIndex].processingOption) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(topAnchorID, anchor: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(workspaceBackground)
        }
        .confirmationDialog(
            "Discard the current translation draft?",
            isPresented: $showingCancelConfirmation
        ) {
            Button("Discard Draft", role: .destructive) {
                viewModel.cancelTranslation(forCardIndex: cardIndex)
            }
            Button("Keep Draft", role: .cancel) {}
        } message: {
            Text("Cancel removes the partial translation kept on this card.")
        }
    }

    @ViewBuilder
    private var contentPanel: some View {
        switch currentCard.processingOption {
        case .useAvailable:
            useAvailablePanel
        case .searchOnline:
            searchOnlinePanel
        case .translateWithLLM:
            translatePanel
        }
    }

    private var sourceModeCards: some View {
        workspaceSection(title: "Source Mode", subtitle: "Choose how this workspace gets its subtitle.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                modeTile(
                    title: SubtitleProcessingOption.useAvailable.title,
                    subtitle: "Choose from detected embedded tracks and local sidecars.",
                    systemImage: "tray.full",
                    option: .useAvailable
                )
                modeTile(
                    title: SubtitleProcessingOption.searchOnline.title,
                    subtitle: "Search OpenSubtitles and download a match into this card.",
                    systemImage: "magnifyingglass",
                    option: .searchOnline
                )
                modeTile(
                    title: SubtitleProcessingOption.translateWithLLM.title,
                    subtitle: "Generate a new subtitle from an existing source track.",
                    systemImage: "sparkles",
                    option: .translateWithLLM
                )
            }
        }
    }

    private var useAvailablePanel: some View {
        let candidates = viewModel.candidates(forCardIndex: cardIndex)

        return workspaceSection(title: "Available Candidates", subtitle: "Pick a local or embedded subtitle for \(currentLanguage.displayName).") {
            VStack(alignment: .leading, spacing: 12) {
                if let warning = viewModel.embeddedExtractionWarning(forCardIndex: cardIndex) {
                    infoBanner(
                        warning,
                        systemImage: "exclamationmark.triangle",
                        foreground: .orange
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    Picker(
                        "Candidate",
                        selection: Binding(
                            get: { currentCard.selectedCandidateID ?? "" },
                            set: { newID in
                                viewModel.cards[cardIndex].selectedCandidateID = newID.isEmpty ? nil : newID
                                viewModel.candidateSelectionChanged(forCardIndex: cardIndex)
                            }
                        )
                    ) {
                        Text("Select...").tag("")
                        ForEach(candidates) { candidate in
                            Text(candidate.displayTitle).tag(candidate.id)
                        }
                    }
                    .disabled(candidates.isEmpty)
                    .frame(maxWidth: 360, alignment: .leading)

                    Spacer(minLength: 8)

                    importButton
                }

                if candidates.isEmpty {
                    infoBanner(
                        "No matching subtitle candidates are available for this language yet.",
                        systemImage: "tray",
                        foreground: .secondary
                    )
                } else if let selectedCandidate = viewModel.selectedCandidate(forCardIndex: cardIndex),
                          selectedCandidate.languageProfile != nil || !selectedCandidate.qualitySignals.isEmpty {
                    candidateQualityCard(selectedCandidate, showUseAnyway: false)
                } else if !reviewedCandidates(in: candidates).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Downloaded candidates needing review")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(reviewedCandidates(in: candidates)) { candidate in
                            candidateQualityCard(candidate, showUseAnyway: true)
                        }
                    }
                }
            }
        }
    }

    private var searchOnlinePanel: some View {
        workspaceSection(title: "OpenSubtitles Search", subtitle: "Find a subtitle online, then download it into this workspace.") {
            VStack(alignment: .leading, spacing: 12) {
                if currentCard.searchResults.isEmpty, let message = currentCard.searchMessage {
                    infoBanner(
                        message,
                        systemImage: "magnifyingglass",
                        foreground: searchMessageColor
                    )
                }

                if viewModel.isProcessing {
                    processingRow
                } else {
                    Button {
                        viewModel.searchOpenSubtitles(forCardIndex: cardIndex, language: currentLanguage)
                    } label: {
                        Label("Search OpenSubtitles", systemImage: "magnifyingglass")
                    }
                    .disabled(viewModel.selectedVideoURL == nil)
                }

                if !currentCard.searchResults.isEmpty {
                    Divider()

                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(currentCard.searchResults.enumerated()), id: \.element.id) { index, result in
                            Button {
                                viewModel.downloadSubtitle(result, forCardIndex: cardIndex)
                            } label: {
                                searchResultRow(result)
                            }
                            .buttonStyle(.plain)

                            if index < currentCard.searchResults.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var translatePanel: some View {
        let sourceOptions = viewModel.translationSourceOptions(forCardIndex: cardIndex)
        let referenceOptions = viewModel.translationReferenceOptions(forCardIndex: cardIndex)

        return workspaceSection(title: "Translation Setup", subtitle: "Generate a new subtitle for \(currentLanguage.displayName) from an existing text track.") {
            VStack(alignment: .leading, spacing: StudioSpacing.md) {
                if sourceOptions.isEmpty {
                    infoBanner(
                        "Import, detect, or search at least one text subtitle before translating.",
                        systemImage: "exclamationmark.triangle",
                        foreground: .orange
                    )
                } else {
                    translationPickerSection(sourceOptions: sourceOptions, referenceOptions: referenceOptions)

                    Divider()

                    VStack(alignment: .leading, spacing: StudioSpacing.md) {
                        translationStatusPanel
                        translationActionRow(sourceOptions: sourceOptions)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func translationPickerSection(
        sourceOptions: [SubtitleCandidate],
        referenceOptions: [SubtitleCandidate]
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioSpacing.sm) {
            pickerSectionLabel("Translate From")
            Picker(
                "",
                selection: Binding(
                    get: {
                        currentCard.translateState.sourceCandidateID
                            ?? sourceOptions.first(where: { $0.language != currentLanguage })?.id
                            ?? sourceOptions.first?.id
                    },
                    set: { newValue in
                        viewModel.cards[cardIndex].translateState.sourceCandidateID = newValue
                    }
                )
            ) {
                ForEach(sourceOptions) { option in
                    Text(option.translationSourceLabel).tag(option.id as String?)
                }
            }
            .pickerStyle(.menu)
            .disabled(viewModel.isTranslationLocked(forCardIndex: cardIndex) || currentCard.translateState.isTranslating)

            pickerSectionLabel("Primary Reference (Translation Pivot)")
            Picker(
                "",
                selection: Binding(
                    get: { currentCard.translateState.referenceCandidateID },
                    set: { newValue in
                        viewModel.setPrimaryReference(newValue, forCardIndex: cardIndex)
                        if newValue == nil {
                            viewModel.cards[cardIndex].translateState.referenceWarningMessage = ""
                            viewModel.cards[cardIndex].translateState.usedReferenceSelection = nil
                        }
                    }
                )
            ) {
                Text("None").tag(nil as String?)
                ForEach(referenceOptions) { option in
                    Text(option.translationSourceLabel).tag(option.id as String?)
                }
            }
            .pickerStyle(.menu)
            .disabled(viewModel.isTranslationLocked(forCardIndex: cardIndex) || currentCard.translateState.isTranslating)

            if referenceOptions.isEmpty {
                Text("No eligible reference subtitles are available yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if currentCard.translateState.referenceCandidateID == nil {
                Text("The primary reference is the high-trust semantic pivot the LLM consults while generating the target translation. Leave on None for source-only translation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Used by the LLM as the main source of meaning for translation. Pair with a secondary cultural anchor below to flag culturally neutralized lines.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            let secondaryOptions = viewModel.translationSecondaryReferenceOptions(forCardIndex: cardIndex)
            pickerSectionLabel("Secondary Reference (Cultural Anchor)")
            Picker(
                "",
                selection: Binding(
                    get: { currentCard.translateState.secondaryReferenceCandidateID },
                    set: { newValue in
                        viewModel.setSecondaryReference(newValue, forCardIndex: cardIndex)
                    }
                )
            ) {
                Text("None").tag(nil as String?)
                ForEach(secondaryOptions) { option in
                    Text(option.translationSourceLabel).tag(option.id as String?)
                }
            }
            .pickerStyle(.menu)
            .disabled(
                viewModel.isTranslationLocked(forCardIndex: cardIndex)
                    || currentCard.translateState.isTranslating
                    || currentCard.translateState.referenceCandidateID == nil
            )

            if currentCard.translateState.secondaryReferenceCandidateID == nil {
                Text("Optional native-language subtitle (e.g. the original language of the dialogue). When set, BridgeSub aligns it to the primary and flags cues where the primary may have neutralized cultural flavor.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                let summary = viewModel.preAlignmentSummary(forCardIndex: cardIndex)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if case .failed(let message) = viewModel.preAlignmentState(forCardIndex: cardIndex) {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            pickerSectionLabel("Media Title (Optional)")
            TextField(
                "e.g. Parasite",
                text: Binding(
                    get: { viewModel.mediaTitle(forCardIndex: cardIndex) },
                    set: { viewModel.setMediaTitle($0, forCardIndex: cardIndex) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .disabled(viewModel.isTranslationLocked(forCardIndex: cardIndex) || currentCard.translateState.isTranslating)

            Text("Including the title (and year) consistently improves LLM subtitle translation quality (research-backed). Leave empty if unknown.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let contextTokens = viewModel.environmentContextWindowTokens(forCardIndex: cardIndex)

            pickerSectionLabel("Translation Instructions (Optional)")
            TextField(
                "Scene context or instructions (e.g. police interrogation, sitcom argument, preserve honorifics)",
                text: Binding(
                    get: { currentCard.translateState.instructions },
                    set: { viewModel.cards[cardIndex].translateState.instructions = $0 }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .lineLimit(2...4)
            .disabled(viewModel.isTranslationLocked(forCardIndex: cardIndex) || currentCard.translateState.isTranslating)

            Text("Optional. Describe the scene or add style guidance. Applies to this card only.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let tokens = contextTokens {
                let cueCount = max(1, currentCard.translateState.totalCueCount > 0
                    ? currentCard.translateState.totalCueCount
                    : currentCard.loadedDocument?.cues.count ?? 0)
                let estTokens = cueCount * 60
                let fraction = min(1.0, Double(estTokens) / Double(tokens))
                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    HStack {
                        pickerSectionLabel("Context Budget")
                        Spacer()
                        if fraction < 0.8 {
                            Text("Single-pass eligible")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                    ProgressView(value: fraction)
                        .scaleEffect(y: 0.7)
                    Text("~\(max(1, estTokens / 1000))K / \(tokens / 1000)K tokens (estimate)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var translationStatusPanel: some View {
        let translateState = currentCard.translateState

        return VStack(alignment: .leading, spacing: StudioSpacing.sm) {
            HStack(spacing: StudioSpacing.xs) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .foregroundStyle(StudioColor.textSecondary)
                Text("Translation Status")
                    .font(StudioFont.sectionHeader)
                    .foregroundStyle(StudioColor.text)
            }

            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                if !viewModel.translationProgressLabel(forCardIndex: cardIndex).isEmpty {
                    processingRow
                }

                if translateState.totalCueCount > 0 {
                    ProgressView(
                        value: Double(translateState.completedCueCount) / Double(max(translateState.totalCueCount, 1))
                    )
                    .scaleEffect(y: 0.7)

                    HStack(spacing: StudioSpacing.sm) {
                        Label("\(translateState.completedCueCount)/\(translateState.totalCueCount) cues", systemImage: "text.line.first.and.arrowtriangle.forward")
                        Label(viewModel.translationModelName(forCardIndex: cardIndex), systemImage: "cpu")
                    }
                    .font(StudioFont.caption)
                    .foregroundStyle(StudioColor.textSecondary)
                }

                if let referenceSummary = viewModel.translationReferenceRunSummary(forCardIndex: cardIndex) {
                    Label(referenceSummary, systemImage: "text.quote")
                        .font(StudioFont.caption)
                        .foregroundStyle(StudioColor.textSecondary)
                }

                if !translateState.reviewSummary.isEmpty {
                    Text(translateState.reviewSummary)
                        .font(StudioFont.caption)
                        .foregroundStyle(StudioColor.textSecondary)
                }

                if translateState.flaggedCueCount > 0 || translateState.overrideCount > 0 {
                    HStack(spacing: StudioSpacing.sm) {
                        Label("\(translateState.flaggedCueCount) flagged", systemImage: "exclamationmark.bubble")
                        Label("\(translateState.overrideCount) reference overrides", systemImage: "arrow.triangle.branch")
                    }
                    .font(StudioFont.caption)
                    .foregroundStyle(StudioColor.textSecondary)
                }

                if !translateState.referenceWarningMessage.isEmpty {
                    Text(translateState.referenceWarningMessage)
                        .font(StudioFont.caption)
                        .foregroundStyle(StudioColor.warning)
                }

                if let completedRange = translateState.lastCompletedBatchRange {
                    Text("Last checkpoint: cues \(completedRange.startIndex + 1)-\(completedRange.endIndex + 1)")
                        .font(StudioFont.caption)
                        .foregroundStyle(StudioColor.textSecondary)
                }
            }
        }
        .padding(StudioSpacing.md)
        .background(StudioColor.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .stroke(StudioColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func translationActionRow(sourceOptions: [SubtitleCandidate]) -> some View {
        let translateState = currentCard.translateState
        let hasSource = (
            translateState.sourceCandidateID
                ?? sourceOptions.first(where: { $0.language != currentLanguage })?.id
                ?? sourceOptions.first?.id
        ) != nil
        let locked = viewModel.isTranslationLocked(forCardIndex: cardIndex)

        switch translateState.jobState {
        case .preparing, .running, .pauseRequested, .stopRequested, .cancelling:
            HStack(spacing: 8) {
                Button {
                    viewModel.pauseTranslation(forCardIndex: cardIndex)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .disabled(translateState.pendingControl != nil)

                Button {
                    viewModel.stopTranslation(forCardIndex: cardIndex)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(translateState.pendingControl != nil)

                Button(role: .destructive) {
                    showingCancelConfirmation = true
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .disabled(translateState.jobState == .cancelling)
            }
        case .paused:
            HStack(spacing: 8) {
                Button {
                    viewModel.resumeTranslation(forCardIndex: cardIndex)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                Button(role: .destructive) {
                    showingCancelConfirmation = true
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }
        case .completed:
            EmptyView()
        case .failed, .idle:
            HStack(spacing: 8) {
                Button {
                    if translateState.canResume {
                        viewModel.resumeTranslation(forCardIndex: cardIndex)
                    } else {
                        viewModel.translateSubtitles(forCardIndex: cardIndex)
                    }
                } label: {
                    Label(
                        translateState.canResume ? "Resume" : "Translate to \(currentLanguage.displayName)",
                        systemImage: translateState.canResume ? "play.fill" : "sparkles"
                    )
                }
                .disabled((!translateState.canResume && !hasSource) || locked)

                if translateState.draftDocument != nil && translateState.resumeCursor < max(translateState.totalCueCount, 1) {
                    Button {
                        viewModel.savePartialTranslation(forCardIndex: cardIndex)
                    } label: {
                        Label("Save Partial", systemImage: "square.and.arrow.down")
                    }

                    Button(role: .destructive) {
                        showingCancelConfirmation = true
                    } label: {
                        Label("Discard Draft", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var processingRow: some View {
        HStack(spacing: StudioSpacing.xs) {
            if currentCard.translateState.jobState.isActive {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(StudioFont.caption)
                    .foregroundStyle(StudioColor.textSecondary)
            }

            Text(viewModel.translationProgressLabel(forCardIndex: cardIndex))
                .font(StudioFont.caption)
                .foregroundStyle(StudioColor.textSecondary)
        }
    }

    private var importButton: some View {
        Button {
            presentOpenPanel()
        } label: {
            Label("Import subtitle file", systemImage: "plus.circle")
                .font(StudioFont.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudioColor.textSecondary)
    }

    private var languageSection: some View {
        workspaceSection(title: "Language", subtitle: "The language this workspace represents.") {
            languagePicker
        }
    }

    private var languagePicker: some View {
        Picker(
            "",
            selection: Binding(
                get: { currentCard.language },
                set: { newLanguage in
                    viewModel.cards[cardIndex].language = newLanguage
                    viewModel.languageSelectionChanged(forCardIndex: cardIndex)
                }
            )
        ) {
            ForEach(viewModel.languageAvailability) { availability in
                Text(availability.pickerLabel).tag(availability.language)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func modeTile(
        title: String,
        subtitle: String,
        systemImage: String,
        option: SubtitleProcessingOption
    ) -> some View {
        Button {
            viewModel.cards[cardIndex].processingOption = option
        } label: {
            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                HStack(alignment: .center, spacing: StudioSpacing.sm) {
                    Image(systemName: systemImage)
                        .font(.headline)
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if currentCard.processingOption == option {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(subtitle)
                    .font(StudioFont.caption)
                    .foregroundStyle(StudioColor.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(StudioSpacing.md)
            .background(modeTileBackground(for: option))
            .overlay(modeTileBorder(for: option))
            .clipShape(RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func searchResultRow(_ result: OpenSubtitleSearchResult) -> some View {
        HStack(alignment: .top, spacing: StudioSpacing.md) {
            VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                HStack(spacing: StudioSpacing.xs) {
                    Text(result.languageName)
                        .font(.callout.weight(.medium))
                    if result.hd {
                        badge("HD", color: .blue)
                            .help("High-definition release flag.")
                    }
                    if result.movieHashMatch {
                        badge("Hash", color: .green)
                    }
                }

                qualitySignalsGrid(result.qualitySignals)

                if let featureSummary = result.featureSummary {
                    Text(featureSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let releaseSummary = result.releaseSummary {
                    Text(releaseSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text(result.fileFormat.uppercased())
                    if let fileSize = result.fileSize {
                        Text(formatFileSize(fileSize))
                    }
                    if let votes = result.votes, votes > 0 {
                        Text("\(votes) votes")
                    }
                    Text("\(result.downloads) downloads")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if let comments = result.comments, !comments.isEmpty {
                    Text(comments)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Image(systemName: "arrow.down.circle")
                .font(.headline)
                .foregroundStyle(StudioColor.textSecondary)
        }
        .padding(.vertical, StudioSpacing.xs)
        .contentShape(Rectangle())
    }

    private func candidateQualityCard(_ candidate: SubtitleCandidate, showUseAnyway: Bool) -> some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xs) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    HStack(spacing: 4) {
                        Text(candidate.sourceLabel)
                            .font(.caption.weight(.medium))
                        candidateKindBadge(candidate.kind)
                    }
                    if let profile = candidate.languageProfile {
                        Text(profile.summary)
                            .font(.caption2)
                            .foregroundStyle(profile.reviewRequired ? .orange : .secondary)
                    }
                    if let path = candidate.relativePath, path.contains("/") {
                        Text((path as NSString).deletingLastPathComponent + "/")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if showUseAnyway {
                    Button("Use anyway") {
                        viewModel.useReviewedCandidate(candidate.id, forCardIndex: cardIndex)
                    }
                    .font(StudioFont.caption)
                }
            }

            qualitySignalsGrid(candidate.qualitySignals)

            if let profile = candidate.languageProfile {
                if !profile.warnings.isEmpty {
                    ForEach(profile.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                if !profile.previewLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Preview")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(profile.previewLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(StudioSpacing.sm)
        .background(StudioColor.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .stroke(StudioColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
    }

    private func qualitySignalsGrid(_ signals: [CandidateQualitySignal]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(signals) { signal in
                badge(signal.label, color: color(for: signal.severity))
                    .help(signal.explanation)
            }
        }
    }

    private func reviewedCandidates(in candidates: [SubtitleCandidate]) -> [SubtitleCandidate] {
        candidates.filter { $0.reviewRequired }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = [
            .plainText,
            .text,
            UTType(filenameExtension: "srt"),
            UTType(filenameExtension: "ass"),
            UTType(filenameExtension: "ssa"),
            UTType(filenameExtension: "vtt"),
            UTType(filenameExtension: "sub")
        ].compactMap { $0 }
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.handleImportedURL(url, kind: .cardFallback(cardIndex: cardIndex))
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(StudioFont.tag)
            .padding(.horizontal, StudioSpacing.sm)
            .padding(.vertical, StudioSpacing.xxs)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func pickerSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(StudioFont.caption)
            .foregroundStyle(StudioColor.textSecondary)
    }

    private func infoBanner(_ text: String, systemImage: String, foreground: Color) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(StudioFont.caption)
        .foregroundStyle(foreground)
        .padding(StudioSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(foreground.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .strokeBorder(foreground.opacity(0.18))
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
    }

    private func workspaceSection<Content: View>(
        title: String? = nil,
        subtitle: String? = nil,
        spacing: CGFloat = StudioSpacing.sm,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(StudioFont.sectionHeader)
                        .foregroundStyle(StudioColor.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(StudioFont.caption)
                            .foregroundStyle(StudioColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content()
        }
        .padding(StudioSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColor.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .stroke(StudioColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous))
    }

    private var workspaceBackground: some View {
        RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
            .fill(StudioColor.backgroundElevated)
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                    .stroke(StudioColor.border.opacity(0.8), lineWidth: 1)
            )
    }

    private func modeTileBackground(for option: SubtitleProcessingOption) -> some ShapeStyle {
        currentCard.processingOption == option
            ? AnyShapeStyle(StudioColor.accent.opacity(0.14))
            : AnyShapeStyle(StudioColor.surface)
    }

    private func modeTileBorder(for option: SubtitleProcessingOption) -> some View {
        RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
            .strokeBorder(
                currentCard.processingOption == option ? StudioColor.accent.opacity(0.45) : StudioColor.border,
                lineWidth: currentCard.processingOption == option ? 1.5 : 1
            )
    }

    private var currentCard: CardState {
        viewModel.cards[cardIndex]
    }

    private var currentLanguage: LanguageOption {
        currentCard.language
    }

    private var searchMessageColor: Color {
        currentCard.searchResults.isEmpty ? .secondary : .orange
    }

    @ViewBuilder
    private func candidateKindBadge(_ kind: CueKind?) -> some View {
        switch kind {
        case .sdh:         kindBadge("SDH", color: .orange)
        case .forcedNarrative: kindBadge("Forced", color: .purple)
        case .ad:          kindBadge("Ad", color: .red)
        default:           EmptyView()
        }
    }

    private func kindBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(color.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func color(for severity: CandidateQualitySeverity) -> Color {
        switch severity {
        case .positive:
            return .green
        case .info:
            return .blue
        case .review:
            return .orange
        case .warning:
            return .red
        }
    }
}
