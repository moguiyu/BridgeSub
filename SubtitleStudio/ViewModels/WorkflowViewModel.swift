import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct PreviewMergeState: Equatable, Sendable {
    var displayedCues: [BilingualCue] = []
    var fullCues: [BilingualCue]? = nil
    var totalCueCount: Int = 0
    var loadedCueCount: Int = 0
    var lowConfidenceCount: Int = 0
    var sourceDocument: SubtitleDocument?
    var targetDocument: SubtitleDocument?
    var isBuildingFullMerge = false
    var usesSourceDraft = false
    var usesTargetDraft = false

    var hasMoreCues: Bool {
        loadedCueCount < totalCueCount
    }

    var isDraftPreview: Bool {
        usesSourceDraft || usesTargetDraft
    }
}

@MainActor
@Observable
final class WorkflowViewModel {
    private static let previewPageSize = 50

    enum FileImportKind {
        case video
        case cardFallback(cardIndex: Int)
    }

    var phase: WorkflowPhase = .idle
    var selectedVideoURL: URL?
    var inspectionReport: VideoInspectionReport?
    var inventory: SubtitleInventory?
    var cards: [CardState]
    var previewMode: PreviewMode = .none
    var previewState = PreviewMergeState()
    var mergedDocument: MergedSubtitleDocument?
    var qualityReport: SubtitleQualityReport?
    var isQualityEvaluationPending = false
    var qualityOverrideAcknowledged = false
    var openSubtitlesSettings = OpenSubtitlesSettings()
    var exportMode: ExportMode = .externalOnly
    var embedDestinationMode: EmbedDestinationMode = .createNewFile
    var exportFormat: SubtitleFormatKind = .srt
    var isResolvingSelection = false
    var isProcessing = false
    var processingLabel = ""
    var processingProgress: Double = 0
    var spotCheckEnabled = false
    var spotCheckSampleSize = 10
    var selectedProcessingOption: SubtitleProcessingOption = .useAvailable
    var statusLines: [WorkflowLogEntry] = [
        WorkflowLogEntry(message: "Ready.", kind: .info)
    ]
    var lastError: String?
    var lastSavedSidecarURL: URL?
    var lastEmbeddedOutputURL: URL?
    var isVADAnalysisEnabled = true
    var selectedAudioTrackIndex: Int = 0
    var isVADAnalysisRunning = false
    var lastVADResult: VADArbitrationResult?
    var autoVADReminder = false

    var providerSettings: ProviderSettings {
        ProviderSettings.load()
    }

    var providerPresets: [TranslationProviderPresetConfiguration] {
        providerSettings.availablePresets
    }

    private let environment: AppEnvironment
    private var loadedSelectionKeys: [String?]
    private var currentResolutionTask: Task<Void, Never>?
    private var mergePreviewTask: Task<Void, Never>?
    private var currentResolutionTaskToken = UUID()
    private var mergePreviewTaskToken = UUID()
    private var mergeEventStream: AsyncStream<MergeEvent>?
    private var qualityEventStream: AsyncStream<QualityEvent>?
    private var translationTask: Task<Void, Never>?
    private var activeTranslationCardIndex: Int?
    private var mergedDocumentCache: [String: MergedSubtitleDocument] = [:]

    init(environment: AppEnvironment) {
        self.environment = environment
        let lastUsedProviderPresetID = ProviderSettings.load().lastUsedProviderPresetID
        self.cards = Self.defaultCards(lastUsedProviderPresetID: lastUsedProviderPresetID)
        self.loadedSelectionKeys = [nil, nil]
    }

    func handleImportedURL(_ url: URL, kind: FileImportKind) {
        switch kind {
        case .video:
            selectedVideoURL = url
            phase = .videoSelected
            status("Selected video: \(url.lastPathComponent)")
            Task { await inspectVideo() }
        case .cardFallback(let cardIndex):
            do {
                try importSubtitleCandidate(
                    at: url,
                    for: cards[cardIndex].language,
                    cardIndex: cardIndex,
                    origin: .localFile,
                    selectImportedCandidate: true
                )
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func inspectVideo() async {
        guard let selectedVideoURL else {
            fail("Select a video file first.")
            return
        }

        resetSelectionState(keepVideo: true)

        do {
            let report = try await environment.mediaInspectionService.inspect(videoURL: selectedVideoURL)
            inspectionReport = report
            inventory = environment.inventoryService.buildInventory(from: report)
            phase = .inspected

            autoSelectLanguages()
            await resolveSelections()

            let embeddedCount = report.embeddedSubtitleTracks.count
            let sidecarCount = report.localSubtitleSidecars.count
            let audioCount = report.audioStreams.count
            status("Inspection finished. Found \(audioCount) audio streams, \(embeddedCount) embedded subtitle tracks, and \(sidecarCount) sidecars.")

            let ffprobeStatus = environment.toolRegistry.status(for: .ffprobe)
            if ffprobeStatus.isAvailable {
                status("Inspection backend: \(ffprobeStatus.summaryLabel).")
            }
        } catch {
            fail(error, context: "inspectVideo")
        }
    }

    func languageSelectionChanged(forCardIndex cardIndex: Int) {
        guard cards.indices.contains(cardIndex) else { return }

        phase = .languagesChosen
        qualityOverrideAcknowledged = false
        cards[cardIndex].searchResults = []
        resetTranslationState(forCardIndex: cardIndex)

        if selectedCandidate(forCardIndex: cardIndex) == nil {
            cards[cardIndex].selectedCandidateID = nil
            cards[cardIndex].loadedDocument = nil
            loadedSelectionKeys[cardIndex] = nil
        }

        autoSelectBestCandidate(for: cardIndex)
        resolveCurrentSelections()
    }

    func startProcessing() {
        resolveCurrentSelections()
    }

    func searchOpenSubtitles(forCardIndex cardIndex: Int, language: LanguageOption? = nil) {
        guard cards.indices.contains(cardIndex), !isProcessing, let videoURL = selectedVideoURL else { return }

        let searchLanguage = language ?? cards[cardIndex].language
        let openSubtitlesLanguageCode = searchLanguage.openSubtitlesCode
        isProcessing = true
        processingLabel = "Searching OpenSubtitles..."
        cards[cardIndex].searchResults = []
        cards[cardIndex].searchMessage = nil
        status("Searching OpenSubtitles for Card \(cardIndex + 1): \(searchLanguage.displayName) (\(openSubtitlesLanguageCode)).")

        Task {
            do {
                let hash = try OpenSubtitlesRESTClient.computeMovieHash(fileURL: videoURL)
                let response = try await environment.openSubtitlesService.searchSubtitles(
                    videoHash: hash,
                    languages: [openSubtitlesLanguageCode],
                    videoURL: videoURL
                )
                cards[cardIndex].searchResults = response.results
                cards[cardIndex].searchMessage = searchMessage(for: response)
                isProcessing = false
                processingLabel = ""
                status("Found \(response.results.count) subtitle(s) for Card \(cardIndex + 1) \(searchLanguage.displayName).")
            } catch {
                isProcessing = false
                processingLabel = ""
                fail(error, context: "searchOpenSubtitles")
            }
        }
    }

    func downloadSubtitle(_ result: OpenSubtitleSearchResult, forCardIndex cardIndex: Int) {
        guard cards.indices.contains(cardIndex), !isProcessing else { return }

        isProcessing = true
        processingLabel = "Downloading..."
        let language = cards[cardIndex].language

        Task {
            let destination: URL
            do {
                let downloadedURL = try await environment.openSubtitlesService.downloadSubtitle(subtitleID: result.subtitleID)
                destination = try moveDownloadedSubtitle(downloadedURL, for: language, sourceKind: .openSubtitles, preferredExtension: "srt")
            } catch {
                isProcessing = false
                processingLabel = ""
                fail(error, context: "downloadSubtitle")
                return
            }

            do {
                let shouldSelectDownloadedCandidate = cards[cardIndex].selectedCandidateID == nil
                let candidate = try importSubtitleCandidate(
                    at: destination,
                    for: language,
                    cardIndex: cardIndex,
                    origin: .openSubtitles,
                    selectImportedCandidate: shouldSelectDownloadedCandidate,
                    sourceSearchResult: result
                )
                isProcessing = false
                processingLabel = ""
                if candidate.reviewRequired {
                    status("Downloaded subtitle needs review: \(candidate.languageProfile?.summary ?? "quality signals suggest review before merging.").")
                } else {
                    status("Downloaded \(result.languageName) subtitle and added it to Card \(cardIndex + 1).")
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                isProcessing = false
                processingLabel = ""
                fail("Downloaded subtitle could not be previewed (\(result.downloadFailureContext)): \(error.localizedDescription)")
            }
        }
    }

    private func searchMessage(for response: OpenSubtitleSearchResponse) -> String? {
        if response.results.isEmpty, let queryTitle = response.queryTitle {
            if let queryYear = response.queryYear {
                return "No matching subtitles found for \(queryTitle) (\(queryYear))."
            }
            return "No matching subtitles found for \(queryTitle)."
        }

        if response.filteredCount > 0 {
            return "Filtered \(response.filteredCount) mismatched OpenSubtitles result(s)."
        }

        return nil
    }

    func translateSubtitles(forCardIndex cardIndex: Int) {
        startTranslation(forCardIndex: cardIndex, resumeExistingDraft: false)
    }

    func resumeTranslation(forCardIndex cardIndex: Int) {
        startTranslation(forCardIndex: cardIndex, resumeExistingDraft: true)
    }

    func pauseTranslation(forCardIndex cardIndex: Int) {
        guard cards.indices.contains(cardIndex),
              activeTranslationCardIndex == cardIndex,
              cards[cardIndex].translateState.jobState.isActive else { return }

        cards[cardIndex].translateState.pendingControl = .pause
        cards[cardIndex].translateState.jobState = .pauseRequested
        cards[cardIndex].translateState.statusMessage = "Pause requested. Finishing the current batch..."
    }

    func stopTranslation(forCardIndex cardIndex: Int) {
        guard cards.indices.contains(cardIndex),
              activeTranslationCardIndex == cardIndex,
              cards[cardIndex].translateState.jobState.isActive else { return }

        cards[cardIndex].translateState.pendingControl = .stop
        cards[cardIndex].translateState.jobState = .stopRequested
        cards[cardIndex].translateState.statusMessage = "Stop requested. Preserving the current draft after this batch..."
    }

    func cancelTranslation(forCardIndex cardIndex: Int) {
        guard cards.indices.contains(cardIndex) else { return }

        if activeTranslationCardIndex == cardIndex,
           cards[cardIndex].translateState.jobState.isActive {
            cards[cardIndex].translateState.pendingControl = .cancel
            cards[cardIndex].translateState.jobState = .cancelling
            cards[cardIndex].translateState.statusMessage = "Cancel requested. Discarding the draft after this batch..."
            return
        }

        clearTranslationDraft(forCardIndex: cardIndex)
    }

    func savePartialTranslation(forCardIndex cardIndex: Int) {
        guard cards.indices.contains(cardIndex),
              let draftDocument = cards[cardIndex].translateState.draftDocument else { return }

        do {
            let savedURL = try saveTranslatedSidecar(draftDocument)
            cards[cardIndex].translateState.draftSaveURL = savedURL
            try importSubtitleCandidate(
                at: savedURL,
                for: cards[cardIndex].language,
                cardIndex: cardIndex,
                origin: .llmTranslation,
                selectImportedCandidate: false
            )
            status("Saved partial \(cards[cardIndex].language.displayName) translation from Card \(cardIndex + 1).")
        } catch {
            fail(error, context: "savePartialTranslation")
        }
    }

    func candidateSelectionChanged(forCardIndex cardIndex: Int) {
        guard cards.indices.contains(cardIndex) else { return }

        qualityOverrideAcknowledged = false
        resetTranslationState(forCardIndex: cardIndex)

        if selectedCandidate(forCardIndex: cardIndex) == nil {
            cards[cardIndex].selectedCandidateID = nil
            cards[cardIndex].loadedDocument = nil
            loadedSelectionKeys[cardIndex] = nil
        }

        resolveCurrentSelections()
    }

    func mergeSelectedSubtitles(forceOverride: Bool = false) {
        guard let doc0 = cards[0].loadedDocument else {
            fail("Select a subtitle on Card 1 first.")
            return
        }
        guard let doc1 = cards[1].loadedDocument else {
            fail("Select a subtitle on Card 2 first.")
            return
        }

        qualityOverrideAcknowledged = qualityOverrideAcknowledged || forceOverride
        if mergedDocument == nil {
            previewState.isBuildingFullMerge = true
            startBackgroundMerge(source: doc0, target: doc1, cacheKey: currentMergeCacheKey)
            status("Preparing merged \(cards[0].language.displayName) + \(cards[1].language.displayName) subtitles.")
            return
        }

        status("Merged \(cards[0].language.displayName) + \(cards[1].language.displayName) subtitles.")
    }

    func exportFormatChanged() {
        status("Export format changed to \(exportFormat.fileExtension)")
    }

    func analyzeWithVADAndRerunMerge() async {
        guard let videoURL = selectedVideoURL,
              let sourceDoc = cards[0].loadedDocument,
              let targetDoc = cards[1].loadedDocument else {
            fail("Load subtitles for both cards first.")
            return
        }

        autoVADReminder = false
        isVADAnalysisRunning = true
        status("Analyzing audio with voice detection...")
        defer { isVADAnalysisRunning = false }

        do {
            let vadResult = try await environment.vadService.analyze(
                videoURL: videoURL,
                source: sourceDoc,
                target: targetDoc,
                audioTrackIndex: selectedAudioTrackIndex
            )
            lastVADResult = vadResult

            let s = String(format: "%.0f%%", vadResult.sourceAverageScore * 100)
            let t = String(format: "%.0f%%", vadResult.targetAverageScore * 100)
            let sec = String(format: "%.1f", vadResult.elapsedSeconds)
            status("VAD: source=\(s) target=\(t) in \(sec)s. Rerunning merge with voice data.")

            mergedDocumentCache.removeAll()
            mergedDocument = nil
            previewState = PreviewMergeState()
            startBackgroundMerge(
                source: sourceDoc, target: targetDoc,
                cacheKey: currentMergeCacheKey, vadResult: vadResult
            )
        } catch {
            fail(error, context: "VAD analysis")
        }
    }

    func saveSidecar() {
        isProcessing = true
        processingLabel = "Saving sidecar..."
        defer {
            isProcessing = false
            processingLabel = ""
        }

        guard let mergedDocument, let selectedVideoURL else {
            fail("Merge the selected subtitles before saving a sidecar.")
            return
        }

        let destination = uniqueOutputURL(base: mergedDocument.defaultSidecarURL(for: selectedVideoURL))

        do {
            try environment.exportService.export(mergedDocument, to: destination)
            lastSavedSidecarURL = destination
            phase = .exportReady
            status("Saved sidecar subtitle to \(destination.lastPathComponent).")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func embedIntoVideo() async {
        isProcessing = true
        processingLabel = "Embedding..."
        defer {
            isProcessing = false
            processingLabel = ""
        }

        guard let mergedDocument, let inspectionReport else {
            fail("Merge the subtitles before embedding them into the video.")
            return
        }

        do {
            let destination = try await environment.mkvEmbeddingService.embed(
                merged: mergedDocument,
                inspectionReport: inspectionReport,
                destinationMode: embedDestinationMode
            )
            lastEmbeddedOutputURL = destination
            phase = .exportReady
            if embedDestinationMode == .replaceOriginal {
                status("Replaced original video with embedded subtitles.")
            } else {
                status("Embedded merged subtitles into \(destination.lastPathComponent).")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func validateProviderConfiguration(for presetID: TranslationProviderPresetID? = nil) {
        let settings = providerSettings
        let resolvedPresetID = presetID ?? settings.lastUsedProviderPresetID
        let projectedSettings = settings.projected(for: resolvedPresetID)
        let resolvedProvider = projectedSettings.selectedProvider
        do {
            try environment.openSubtitlesService.validateConfiguration(username: openSubtitlesSettings.username)
            guard let translationProvider = environment.translationProviders[resolvedProvider] else {
                throw WorkflowError.dependencyUnavailable("Selected translation provider is not wired into the app.")
            }

            try translationProvider.validateConfiguration(settings: projectedSettings)
            let providerName = settings.configuration(for: resolvedPresetID).displayName
            status("Provider settings for \(providerName) look valid.")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func translationProviderChanged(forCardIndex cardIndex: Int, presetID: TranslationProviderPresetID) {
        guard cards.indices.contains(cardIndex) else { return }
        cards[cardIndex].translateState.providerPresetID = presetID

        var settings = providerSettings
        guard settings.lastUsedProviderPresetID != presetID else { return }
        settings.lastUsedProviderPresetID = presetID
        settings.persist()
    }

    func saveCredential(account: String, value: String) {
        do {
            try environment.credentialStore.save(value, account: account)
            status("Saved secure setting for \(account).")
        } catch {
            fail(error.localizedDescription)
        }
    }

    var languageAvailability: [LanguageAvailability] {
        inventory?.availableLanguages ?? LanguageOption.supportedLanguages.map {
            .init(language: $0, textCandidateCount: 0, bitmapTrackCount: 0)
        }
    }

    var toolStatuses: [MediaToolStatus] {
        environment.toolRegistry.allStatuses()
    }

    func candidates(forCardIndex cardIndex: Int) -> [SubtitleCandidate] {
        guard cards.indices.contains(cardIndex) else { return [] }
        return inventory?.candidates(for: cards[cardIndex].language) ?? []
    }

    func translationSourceOptions(forCardIndex cardIndex: Int) -> [SubtitleCandidate] {
        guard cards.indices.contains(cardIndex) else { return [] }

        return (inventory?.candidates ?? [])
            .filter { $0.availability == .available && $0.isTextBased }
            .sorted { lhs, rhs in
                if lhs.rankingScore == rhs.rankingScore {
                    return lhs.translationSourceLabel < rhs.translationSourceLabel
                }
                return lhs.rankingScore > rhs.rankingScore
            }
    }

    func translationReferenceOptions(forCardIndex cardIndex: Int) -> [SubtitleCandidate] {
        guard cards.indices.contains(cardIndex) else { return [] }
        let sourceOptions = translationSourceOptions(forCardIndex: cardIndex)
        let sourceCandidateID = effectiveTranslationSourceCandidateID(forCardIndex: cardIndex, sourceOptions: sourceOptions)
        let targetLanguage = cards[cardIndex].language

        return (inventory?.candidates ?? [])
            .filter {
                $0.availability == .available &&
                $0.isTextBased &&
                $0.origin != .llmTranslation &&
                $0.id != sourceCandidateID &&
                $0.language != targetLanguage
            }
            .sorted { lhs, rhs in
                if lhs.rankingScore == rhs.rankingScore {
                    return lhs.translationSourceLabel < rhs.translationSourceLabel
                }
                return lhs.rankingScore > rhs.rankingScore
            }
    }

    private func effectiveTranslationSourceCandidateID(
        forCardIndex cardIndex: Int,
        sourceOptions: [SubtitleCandidate]? = nil
    ) -> String? {
        guard cards.indices.contains(cardIndex) else { return nil }
        if let selectedID = cards[cardIndex].translateState.sourceCandidateID {
            return selectedID
        }

        let options = sourceOptions ?? translationSourceOptions(forCardIndex: cardIndex)
        return options.first(where: { $0.language != cards[cardIndex].language })?.id
            ?? options.first?.id
    }

    func translationReferenceRunSummary(forCardIndex cardIndex: Int) -> String? {
        guard cards.indices.contains(cardIndex),
              let selection = cards[cardIndex].translateState.usedReferenceSelection else { return nil }
        let summary = cards[cardIndex].translateState.referenceAlignmentSummary
        if summary.isEmpty {
            return "Reference subtitle: \(selection.sourceLabel)"
        }
        return "Reference subtitle: \(selection.sourceLabel) · \(summary)"
    }

    func translationModelName(forCardIndex cardIndex: Int) -> String {
        let settings = providerSettings
        return settings.configuration(for: cards[cardIndex].translateState.providerPresetID).model
    }

    func translationProgressLabel(forCardIndex cardIndex: Int) -> String {
        let state = cards[cardIndex].translateState
        let progress = "\(state.completedCueCount)/\(max(state.totalCueCount, 0))"

        switch state.jobState {
        case .preparing:
            return state.statusMessage.isEmpty ? "Preparing translation..." : state.statusMessage
        case .running, .pauseRequested, .stopRequested, .cancelling:
            if let range = state.activeBatchRange {
                return "\(state.statusMessage) Batch \(range.startIndex + 1)-\(range.endIndex + 1) · \(progress)"
            }
            return state.statusMessage.isEmpty ? "Translating... \(progress)" : "\(state.statusMessage) · \(progress)"
        case .paused:
            return state.statusMessage.isEmpty ? "Paused at cue \(state.resumeCursor)." : state.statusMessage
        case .completed:
            return state.statusMessage.isEmpty ? "Translation complete." : state.statusMessage
        case .failed:
            return state.statusMessage.isEmpty ? "Translation failed." : state.statusMessage
        case .idle:
            return state.statusMessage
        }
    }

    var hasActiveTranslation: Bool {
        activeTranslationCardIndex != nil
    }

    var hasPendingWorkflowWork: Bool {
        isProcessing || hasActiveTranslation || isResolvingSelection || previewState.isBuildingFullMerge || isQualityEvaluationPending
    }

    func isTranslationLocked(forCardIndex cardIndex: Int) -> Bool {
        hasActiveTranslation && activeTranslationCardIndex != cardIndex
    }

    func embeddedExtractionWarning(forCardIndex cardIndex: Int) -> String? {
        guard cards.indices.contains(cardIndex),
              let videoURL = inventory?.videoURL ?? selectedVideoURL,
              RemoteMediaPolicy.isLargeRemoteMKV(videoURL),
              candidates(forCardIndex: cardIndex).contains(where: { $0.origin == .embedded }) else {
            return nil
        }

        return "Embedded extraction may scan the full remote MKV; search/download is recommended."
    }

    var adaptiveProcessingOptions: AdaptiveProcessingOptions {
        let hasEmbedded = inspectionReport?.embeddedSubtitleTracks.contains { $0.isTextBased } ?? false
        let hasSidecar = !(inspectionReport?.localSubtitleSidecars.isEmpty ?? true)
        return AdaptiveProcessingOptions(hasEmbedded: hasEmbedded, hasSidecar: hasSidecar)
    }

    var bitmapOnlyLanguageLabels: [String] {
        languageAvailability
            .filter(\.hasBitmapOnlyCandidates)
            .map { "\($0.language.displayName) (\($0.bitmapTrackCount) OCR)" }
    }

    var previewStatusMessage: String? {
        if previewState.isDraftPreview {
            switch (previewState.usesSourceDraft, previewState.usesTargetDraft) {
            case (true, true):
                return "Showing live draft preview for both translating cards."
            case (true, false):
                return "Showing live draft preview for Card 1 while translation continues."
            case (false, true):
                return "Showing live draft preview for Card 2 while translation continues."
            case (false, false):
                break
            }
        }

        if previewState.isBuildingFullMerge {
            return "Showing the beginning of the merged preview while alignment finishes in the background."
        }

        let activeDocuments = cards.indices.compactMap { effectivePreviewDocument(forCardIndex: $0) }
        if previewState.totalCueCount > 0 && activeDocuments.count == 2 {
            return "Showing merged preview for the two selected subtitles."
        }
        if activeDocuments.count == 1 {
            return isResolvingSelection
                ? "Showing one selected subtitle while the other card resolves."
                : "Showing one selected subtitle only."
        }
        return nil
    }

    var previewPlaceholderMessage: String {
        if isResolvingSelection && previewState.displayedCues.isEmpty {
            return "Loading the selected subtitles..."
        }
        if cards.indices.contains(where: { usesDraftPreview(forCardIndex: $0) }) {
            return "Preparing the live translation draft preview..."
        }
        if cards.allSatisfy({ $0.selectedCandidateID == nil }) {
            return "Select subtitles on the two cards to build the merged preview."
        }
        if cards.contains(where: { $0.selectedCandidateID != nil && $0.loadedDocument == nil }) {
            return "Loading the selected subtitle documents..."
        }
        return "Select subtitles on both cards to preview the merge."
    }

    func selectedCandidate(forCardIndex cardIndex: Int) -> SubtitleCandidate? {
        guard cards.indices.contains(cardIndex),
              let selectedID = cards[cardIndex].selectedCandidateID else { return nil }
        return candidates(forCardIndex: cardIndex).first { $0.id == selectedID }
    }

    func useReviewedCandidate(_ candidateID: String, forCardIndex cardIndex: Int) {
        guard cards.indices.contains(cardIndex) else { return }
        cards[cardIndex].selectedCandidateID = candidateID
        candidateSelectionChanged(forCardIndex: cardIndex)
    }

    private func usesDraftPreview(forCardIndex cardIndex: Int) -> Bool {
        guard cards.indices.contains(cardIndex) else { return false }

        let translateState = cards[cardIndex].translateState
        guard translateState.draftDocument != nil, translateState.translatedDocument == nil else {
            return false
        }

        switch translateState.jobState {
        case .preparing, .running, .pauseRequested, .paused, .stopRequested, .cancelling:
            return true
        case .idle, .failed:
            return translateState.resumeCursor > 0
        case .completed:
            return false
        }
    }

    private func effectivePreviewDocument(forCardIndex cardIndex: Int) -> SubtitleDocument? {
        guard cards.indices.contains(cardIndex) else { return nil }
        if usesDraftPreview(forCardIndex: cardIndex) {
            return cards[cardIndex].translateState.draftDocument
        }
        return cards[cardIndex].loadedDocument
    }

    private func refreshPreviewForCurrentState(preserveLoadedCount: Bool = true) {
        let sourceDocument = effectivePreviewDocument(forCardIndex: 0)
        let targetDocument = effectivePreviewDocument(forCardIndex: 1)
        let usesSourceDraft = usesDraftPreview(forCardIndex: 0)
        let usesTargetDraft = usesDraftPreview(forCardIndex: 1)
        let isDraftPreview = usesSourceDraft || usesTargetDraft

        if isDraftPreview {
            mergePreviewTask?.cancel()
            mergedDocument = nil
            qualityReport = nil
            isQualityEvaluationPending = false
        }

        if let sourceDocument, let targetDocument {
            let cacheKey = currentMergeCacheKey
            previewState.isBuildingFullMerge = !isDraftPreview
            previewMode = .bilingual
            phase = .previewReady
            if !isDraftPreview {
                startBackgroundMerge(
                    source: sourceDocument,
                    target: targetDocument,
                    cacheKey: cacheKey,
                    vadResult: lastVADResult
                )
            }
        } else if let sourceDocument {
            publishSingleDocumentPreview(
                document: sourceDocument,
                renderAsSource: true,
                usesDraft: usesSourceDraft,
                preserveLoadedCount: preserveLoadedCount
            )
        } else if let targetDocument {
            publishSingleDocumentPreview(
                document: targetDocument,
                renderAsSource: false,
                usesDraft: usesTargetDraft,
                preserveLoadedCount: preserveLoadedCount
            )
        } else {
            previewState = PreviewMergeState()
            previewMode = .none
            phase = .candidatesResolved
        }
    }

    var previewCues: [BilingualCue] {
        if !previewState.displayedCues.isEmpty {
            return previewState.displayedCues
        }
        if let mergedDocument, !previewState.isDraftPreview {
            return mergedDocument.cues
        }
        if let leftDocument = effectivePreviewDocument(forCardIndex: 0) {
            return buildSingleDocumentPage(document: leftDocument, startIndex: 0, pageSize: Self.previewPageSize, renderAsSource: true)
        }
        if let rightDocument = effectivePreviewDocument(forCardIndex: 1) {
            return buildSingleDocumentPage(document: rightDocument, startIndex: 0, pageSize: Self.previewPageSize, renderAsSource: false)
        }
        return []
    }

    var visiblePreviewCues: [BilingualCue] {
        previewCues
    }

    var previewTotalCueCount: Int {
        if previewState.totalCueCount > 0 {
            return previewState.totalCueCount
        }
        if let mergedDocument, !previewState.isDraftPreview {
            return mergedDocument.cues.count
        }
        if let leftDocument = effectivePreviewDocument(forCardIndex: 0) {
            return leftDocument.cues.count
        }
        if let rightDocument = effectivePreviewDocument(forCardIndex: 1) {
            return rightDocument.cues.count
        }
        return 0
    }

    func loadMoreCues() {
        appendNextPreviewPage()
    }

    var qualityScoreLabel: String {
        guard let score = qualityReport?.score else { return "n/a" }
        return String(format: "%.0f%%", score * 100)
    }

    var alignmentSummaryLine: String {
        qualityReport?.alignmentReport.summaryLine ?? "Alignment summary unavailable."
    }

    var qualityStatusMessage: String? {
        if previewState.isDraftPreview {
            return nil
        }
        if isQualityEvaluationPending {
            return "Quality check running in the background..."
        }
        return qualityReport?.alignmentReport.summaryLine
    }

    var lowConfidencePreviewCount: Int {
        if previewState.isDraftPreview {
            return 0
        }
        if previewState.totalCueCount > 0 || !previewState.displayedCues.isEmpty {
            return previewState.lowConfidenceCount
        }
        return previewCues.reduce(into: 0) { count, cue in
            if cue.alignmentStatus != .matched {
                count += 1
            }
        }
    }

    var canMerge: Bool {
        cards[0].loadedDocument != nil && cards[1].loadedDocument != nil
    }

    var requiresQualityOverride: Bool {
        guard let report = qualityReport else { return false }
        return report.decision != .accept
    }

    var canSaveSidecar: Bool {
        mergedDocument != nil
    }

    var embedCapability: EmbeddedExportCapability? {
        guard let mergedDocument, let inspectionReport else { return nil }
        return environment.mkvEmbeddingService.embedCapability(
            for: inspectionReport,
            merged: mergedDocument,
            destinationMode: embedDestinationMode
        )
    }

    var canEmbedIntoVideo: Bool {
        embedCapability?.isAvailable == true
    }

    var showsEmbedDestinationPicker: Bool {
        exportMode == .externalAndTryEmbeddedMKV
    }

    var embedActionTitle: String {
        embedCapability?.plan?.actionTitle ?? "Embed into Video"
    }

    var embedStatusMessage: String? {
        guard mergedDocument != nil, exportMode == .externalAndTryEmbeddedMKV else { return nil }
        return embedCapability?.message
    }

    var qualityReminderMessage: String? {
        guard let report = qualityReport, report.decision != .accept else { return nil }
        let label = report.decision == .review ? "Review recommended" : "Quality warning"
        return "\(label): \(report.notes.first ?? "The selected subtitle pairing may be unreliable.")"
    }

    var vadHasResult: Bool { lastVADResult != nil }

    var vadSourceScoreLabel: String {
        lastVADResult.map { formatVADScore($0.sourceAverageScore) } ?? "n/a"
    }

    var vadTargetScoreLabel: String {
        lastVADResult.map { formatVADScore($0.targetAverageScore) } ?? "n/a"
    }

    private func formatVADScore(_ score: Double) -> String {
        String(format: "%.0f%%", score * 100)
    }

    var vadMasterSideLabel: String? {
        guard let r = lastVADResult else { return nil }
        return r.sourceAverageScore >= r.targetAverageScore ? "Card 1 (source)" : "Card 2 (target)"
    }

    var vadElapsedLabel: String? {
        guard let r = lastVADResult else { return nil }
        return String(format: "%.1fs", r.elapsedSeconds)
    }

    var vadSpeechSegmentCount: Int {
        lastVADResult?.speechSegments.count ?? 0
    }

    var detectedTimingDriftLabel: String? {
        guard let offset = qualityReport?.alignmentReport.detectedTimingOffsetMilliseconds else { return nil }
        let sign = offset > 0 ? "+" : ""
        return "\(sign)\(offset)ms (corrected)"
    }

    var orphanedSecondaryCount: Int {
        qualityReport?.alignmentReport.orphanedTargetCueIDs.count ?? 0
    }

    var secondaryCoverageAfterInjection: Double {
        guard let report = qualityReport else { return 0 }
        let alignment = report.alignmentReport
        let matched = alignment.matches.filter { $0.targetCueID != nil }.count
        let orphaned = alignment.orphanedTargetCueIDs.count
        let total = matched + orphaned
        return total > 0 ? Double(matched + orphaned) / Double(total) : 1.0
    }

    var showVADReminder: Bool {
        !isVADAnalysisRunning && lastVADResult == nil
            && qualityReport.map({ $0.alignmentReport.matchedCueRatio < 0.70 }) ?? false
            && inspectionReport?.audioStreams.isEmpty == false
    }

    var availableAudioTracks: [AudioTrackCandidate] {
        guard let streams = inspectionReport?.audioStreams, !streams.isEmpty else { return [] }
        let sourceLang = cards[0].loadedDocument?.language
        let recommended = AudioTrackCandidate.recommended(from: streams, preferredLanguage: sourceLang)
        return streams.map { stream in
            AudioTrackCandidate(
                id: stream.id, index: stream.index, codecName: stream.codecName,
                languageCode: stream.languageCode, resolvedLanguage: stream.resolvedLanguage,
                channels: stream.channels, bitrate: stream.bitrate,
                isRecommended: stream.index == (recommended?.index ?? -1)
            )
        }
    }

    func selectionSummary(forCardIndex cardIndex: Int) -> String {
        if let candidate = selectedCandidate(forCardIndex: cardIndex) {
            return candidate.displayTitle
        }
        if let bitmapOnlyMessage = bitmapOnlyMessage(for: cards[cardIndex].language) {
            return bitmapOnlyMessage
        }
        return candidates(forCardIndex: cardIndex).isEmpty ? "No available subtitle candidate" : "Choose a subtitle candidate"
    }

    var defaultSidecarName: String {
        guard let mergedDocument, let selectedVideoURL else { return "Not available yet" }
        return mergedDocument.defaultSidecarURL(for: selectedVideoURL).lastPathComponent
    }

    private static func defaultCards(lastUsedProviderPresetID: TranslationProviderPresetID) -> [CardState] {
        [
            CardState(
                language: .defaultSource,
                processingOption: .useAvailable,
                selectedCandidateID: nil,
                loadedDocument: nil,
                searchResults: [],
                translateState: TranslateState(providerPresetID: lastUsedProviderPresetID)
            ),
            CardState(
                language: .defaultTarget,
                processingOption: .useAvailable,
                selectedCandidateID: nil,
                loadedDocument: nil,
                searchResults: [],
                translateState: TranslateState(providerPresetID: lastUsedProviderPresetID)
            )
        ]
    }

    private func resolveCurrentSelections() {
        currentResolutionTask?.cancel()
        mergePreviewTask?.cancel()
        let taskToken = UUID()
        currentResolutionTaskToken = taskToken
        currentResolutionTask = Task { [weak self] in
            guard let self else { return }
            await self.resolveDocumentsAndQuality()
            await MainActor.run {
                guard self.currentResolutionTaskToken == taskToken else { return }
                self.currentResolutionTask = nil
            }
        }
    }

    private func resolveSelections() async {
        autoSelectBestCandidate(for: 0)
        autoSelectBestCandidate(for: 1)
        phase = .candidatesResolved
        await resolveDocumentsAndQuality()
    }

    private func resolveDocumentsAndQuality() async {
        guard let selectedVideoURL else { return }

        isResolvingSelection = true
        mergedDocument = nil
        qualityReport = nil
        isQualityEvaluationPending = false
        lastSavedSidecarURL = nil
        lastEmbeddedOutputURL = nil

        defer {
            isResolvingSelection = false
        }

        let candidate0 = selectedCandidate(forCardIndex: 0)
        let candidate1 = selectedCandidate(forCardIndex: 1)
        let selectionKey0 = selectionKey(for: candidate0, videoURL: selectedVideoURL)
        let selectionKey1 = selectionKey(for: candidate1, videoURL: selectedVideoURL)

        let shouldReload0 = selectionKey0 != loadedSelectionKeys[0] || cards[0].loadedDocument == nil
        let shouldReload1 = selectionKey1 != loadedSelectionKeys[1] || cards[1].loadedDocument == nil

        async let result0 = loadDocumentResult(
            forCardIndex: 0,
            for: candidate0,
            videoURL: selectedVideoURL,
            shouldReload: shouldReload0,
            currentDocument: cards[0].loadedDocument
        )
        async let result1 = loadDocumentResult(
            forCardIndex: 1,
            for: candidate1,
            videoURL: selectedVideoURL,
            shouldReload: shouldReload1,
            currentDocument: cards[1].loadedDocument
        )

        let (resolved0, resolved1) = await (result0, result1)

        if let error = resolved0.error {
            fail(error, context: "load Card 1")
        }
        if let error = resolved1.error {
            fail(error, context: "load Card 2")
        }

        cards[0].loadedDocument = resolved0.document
        cards[1].loadedDocument = resolved1.document
        loadedSelectionKeys[0] = resolved0.document == nil ? nil : selectionKey0
        loadedSelectionKeys[1] = resolved1.document == nil ? nil : selectionKey1

        normalizeTranslationSources()
        refreshPreviewForCurrentState(preserveLoadedCount: false)
    }

    private func loadDocumentResult(
        forCardIndex cardIndex: Int,
        for candidate: SubtitleCandidate?,
        videoURL: URL,
        shouldReload: Bool,
        currentDocument: SubtitleDocument?
    ) async -> (document: SubtitleDocument?, error: Error?) {
        guard let candidate else {
            return (nil, nil)
        }

        if !shouldReload, let currentDocument {
            return (currentDocument, nil)
        }

        do {
            if case .embedded(let trackIndex) = candidate.locator {
                let backend = environment.subtitleIOService.extractorKind(for: candidate, videoURL: videoURL)?.displayName ?? "unknown backend"
                let remoteNote = remoteExtractionNote(for: videoURL)
                status("Loading Card \(cardIndex + 1) embedded subtitle track \(trackIndex) with \(backend).\(remoteNote)")
            }
            let document = try await Task.detached { [subtitleIOService = self.environment.subtitleIOService] in
                try await subtitleIOService.loadDocument(for: candidate, videoURL: videoURL)
            }.value
            if case .embedded(let trackIndex) = candidate.locator {
                status("Loaded Card \(cardIndex + 1) embedded subtitle track \(trackIndex) with \(document.cues.count) cues.")
            }
            return (document, nil)
        } catch {
            return (nil, error)
        }
    }

    private func publishSingleDocumentPreview(
        document: SubtitleDocument,
        renderAsSource: Bool,
        usesDraft: Bool = false,
        preserveLoadedCount: Bool = false
    ) {
        let pageSize = preserveLoadedCount
            ? max(Self.previewPageSize, previewState.loadedCueCount)
            : Self.previewPageSize
        let page = buildSingleDocumentPage(document: document, startIndex: 0, pageSize: pageSize, renderAsSource: renderAsSource)
        previewState = PreviewMergeState(
            displayedCues: page,
            fullCues: nil,
            totalCueCount: document.cues.count,
            loadedCueCount: page.count,
            lowConfidenceCount: usesDraft ? 0 : page.count,
            sourceDocument: renderAsSource ? document : nil,
            targetDocument: renderAsSource ? nil : document,
            isBuildingFullMerge: false,
            usesSourceDraft: renderAsSource ? usesDraft : false,
            usesTargetDraft: renderAsSource ? false : usesDraft
        )
        previewMode = .sourceOnly
        phase = .previewReady
    }

    private func startBackgroundMerge(
        source: SubtitleDocument,
        target: SubtitleDocument,
        cacheKey: String,
        vadResult: VADArbitrationResult? = nil
    ) {
        // Serve instantly from cache when available
        if let cached = mergedDocumentCache[cacheKey] {
            mergedDocument = cached
            previewState.fullCues = cached.cues
            previewState.displayedCues = Array(cached.cues.prefix(Self.previewPageSize))
            previewState.totalCueCount = cached.cues.count
            previewState.loadedCueCount = min(Self.previewPageSize, cached.cues.count)
            previewState.isBuildingFullMerge = false
            previewMode = .bilingual
            phase = .previewReady
            return
        }

        mergePreviewTask?.cancel()
        let token = UUID()
        mergePreviewTaskToken = token
        isQualityEvaluationPending = true

        mergePreviewTask = Task { [weak self] in
            guard let self else { return }

            // pipeline.run() is actor-isolated — call with await from this async context
            let pipeline = await self.environment.pipeline
            let outputFormat = await self.exportFormat
            let (mergeStream, qualityStream) = await pipeline.run(
                source: source,
                target: target,
                vadResult: vadResult,
                outputFormat: outputFormat
            )
            await MainActor.run { [weak self] in
                self?.mergeEventStream = mergeStream
                self?.qualityEventStream = qualityStream
            }

            var accumulatedCues: [BilingualCue] = []

            for await event in mergeStream {
                guard await self.mergePreviewTaskToken == token else { return }
                await MainActor.run {
                    switch event {
                    case .alignmentComplete:
                        break

                    case .segmentBuilt(let segment):
                        let side = segment.isSourceMaster ? "source" : "target"
                        self.status("Segment — master: \(side)")

                    case .pageReady(let cues, let page, _):
                        accumulatedCues.append(contentsOf: cues)
                        self.previewState.fullCues = accumulatedCues
                        if page <= 1 {
                            self.previewState.displayedCues = Array(accumulatedCues.prefix(Self.previewPageSize))
                            self.previewState.loadedCueCount = self.previewState.displayedCues.count
                        }

                    case .mergeComplete(let document):
                        self.mergedDocument = document
                        self.mergedDocumentCache[cacheKey] = document
                        self.previewState.fullCues = document.cues
                        self.previewState.totalCueCount = document.cues.count
                        self.previewState.loadedCueCount = min(
                            max(self.previewState.loadedCueCount, Self.previewPageSize),
                            document.cues.count
                        )
                        self.previewState.displayedCues = Array(
                            document.cues.prefix(self.previewState.loadedCueCount)
                        )
                        self.previewState.lowConfidenceCount = self.lowConfidenceCount(
                            in: self.previewState.displayedCues
                        )
                        self.previewState.isBuildingFullMerge = false
                        self.previewMode = .bilingual
                        self.phase = .previewReady
                        self.mergePreviewTask = nil
                    }
                }
            }

            for await event in qualityStream {
                guard await self.mergePreviewTaskToken == token else { return }
                await MainActor.run {
                    if case .evaluationComplete(let report) = event {
                        self.qualityReport = report
                        self.isQualityEvaluationPending = false
                        self.status(
                            "Quality gate for Card 2 (\(self.cards[1].language.displayName)) is \(report.decision.rawValue)."
                        )
                    }
                }
            }
        }
    }

    private func appendNextPreviewPage() {
        guard previewState.hasMoreCues else { return }

        let startIndex = previewState.loadedCueCount
        let nextPageSize = Self.previewPageSize
        let nextPage: [BilingualCue]

        if let fullCues = previewState.fullCues {
            let endIndex = min(startIndex + nextPageSize, fullCues.count)
            nextPage = Array(fullCues[startIndex..<endIndex])
        } else if let sourceDocument = previewState.sourceDocument {
            nextPage = buildSingleDocumentPage(document: sourceDocument, startIndex: startIndex, pageSize: nextPageSize, renderAsSource: true)
        } else if let targetDocument = previewState.targetDocument {
            nextPage = buildSingleDocumentPage(document: targetDocument, startIndex: startIndex, pageSize: nextPageSize, renderAsSource: false)
        } else {
            return
        }

        previewState.displayedCues.append(contentsOf: nextPage)
        previewState.loadedCueCount = previewState.displayedCues.count
        previewState.lowConfidenceCount = previewState.isDraftPreview ? 0 : lowConfidenceCount(in: previewState.displayedCues)
    }

    private func buildSingleDocumentPage(
        document: SubtitleDocument,
        startIndex: Int,
        pageSize: Int,
        renderAsSource: Bool
    ) -> [BilingualCue] {
        guard startIndex < document.cues.count else { return [] }

        let endIndex = min(startIndex + pageSize, document.cues.count)
        return document.cues[startIndex..<endIndex].map { cue in
            BilingualCue(
                id: cue.id,
                startMilliseconds: cue.startMilliseconds,
                endMilliseconds: cue.endMilliseconds,
                sourceText: renderAsSource ? cue.plainText.normalizedSubtitleText : "",
                targetText: renderAsSource ? "" : cue.plainText.normalizedSubtitleText,
                alignmentConfidence: 0,
                alignmentStatus: .unmatched
            )
        }
    }

    private func lowConfidenceCount(in cues: [BilingualCue]) -> Int {
        cues.reduce(into: 0) { count, cue in
            if cue.alignmentStatus != .matched {
                count += 1
            }
        }
    }

    private func autoSelectLanguages() {
        guard let inventory else { return }

        if inventory.candidates(for: cards[0].language).isEmpty,
           let firstAvailable = inventory.availableLanguages.first(where: { $0.count > 0 && $0.language != cards[1].language })?.language {
            cards[0].language = firstAvailable
        }

        if cards[0].language == cards[1].language,
           let alternative = inventory.availableLanguages.first(where: { $0.count > 0 && $0.language != cards[0].language })?.language {
            cards[1].language = alternative
        }

        if inventory.candidates(for: cards[1].language).isEmpty,
           let fallback = inventory.availableLanguages.first(where: { $0.count > 0 && $0.language != cards[0].language })?.language {
            cards[1].language = fallback
        }
    }

    private func autoSelectBestCandidate(for cardIndex: Int) {
        let availableCandidates = candidates(forCardIndex: cardIndex)
        let selectedID = cards[cardIndex].selectedCandidateID

        if let selectedID, availableCandidates.contains(where: { $0.id == selectedID }) {
            return
        }

        if let videoURL = inventory?.videoURL ?? selectedVideoURL,
           RemoteMediaPolicy.isLargeRemoteMKV(videoURL) {
            let preferredCandidate = availableCandidates.first { $0.origin != .embedded }
            if let preferredCandidate {
                cards[cardIndex].processingOption = .useAvailable
                cards[cardIndex].selectedCandidateID = preferredCandidate.id
            } else if availableCandidates.contains(where: { $0.origin == .embedded }) {
                cards[cardIndex].processingOption = .searchOnline
                cards[cardIndex].selectedCandidateID = nil
            } else {
                cards[cardIndex].selectedCandidateID = nil
            }
        } else {
            cards[cardIndex].selectedCandidateID = availableCandidates.first?.id
        }
        cards[cardIndex].loadedDocument = nil
        loadedSelectionKeys[cardIndex] = nil
    }

    private func moveDownloadedSubtitle(_ downloadedURL: URL, for language: LanguageOption, sourceKind: SubtitleSourceKind, preferredExtension: String) throws -> URL {
        guard let videoURL = inventory?.videoURL ?? selectedVideoURL else {
            return downloadedURL
        }

        let videoDirectory = videoURL.deletingLastPathComponent()
        let videoStem = videoURL.deletingPathExtension().lastPathComponent
        let fileExtension = preferredExtension.isEmpty ? "srt" : preferredExtension.lowercased()
        let baseURL = videoDirectory.appendingPathComponent("\(videoStem).\(language.code)\(sourceKind.fileSuffix).\(fileExtension)")
        let finalURL = uniqueOutputURL(base: baseURL)

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: finalURL)
        return finalURL
    }

    private func startTranslation(forCardIndex cardIndex: Int, resumeExistingDraft: Bool) {
        guard cards.indices.contains(cardIndex) else { return }
        guard activeTranslationCardIndex == nil || activeTranslationCardIndex == cardIndex else {
            fail("Another translation is already running.")
            return
        }

        let translateState = cards[cardIndex].translateState
        let sourceOptions = translationSourceOptions(forCardIndex: cardIndex)
        guard let selectedVideoURL,
              let sourceCandidateID = effectiveTranslationSourceCandidateID(forCardIndex: cardIndex, sourceOptions: sourceOptions),
              let sourceCandidate = sourceOptions.first(where: { $0.id == sourceCandidateID }) else {
            fail("Choose an available subtitle candidate to translate from.")
            return
        }

        cards[cardIndex].translateState.sourceCandidateID = sourceCandidateID
        let effectiveSettings = providerSettings.projected(for: translateState.providerPresetID)

        guard let translationService = environment.translationProviders[effectiveSettings.selectedProvider] else {
            let presetName = providerSettings.configuration(for: translateState.providerPresetID).displayName
            fail("No translation provider configured for \(presetName).")
            return
        }

        let initialResults = resumeExistingDraft
            ? (cards[cardIndex].translateState.draftDocument?.cues.map(\.plainText) ?? [])
            : []
        let resumeCursor = resumeExistingDraft ? cards[cardIndex].translateState.resumeCursor : 0

        processingProgress = 0
        translationTask?.cancel()
        activeTranslationCardIndex = cardIndex
        cards[cardIndex].translateState.pendingControl = nil
        cards[cardIndex].translateState.jobState = .preparing
        cards[cardIndex].translateState.statusMessage = "Preparing translation..."
        cards[cardIndex].translateState.activeBatchRange = nil
        cards[cardIndex].translateState.lastCompletedBatchRange = nil
        cards[cardIndex].translateState.referenceWarningMessage = ""
        cards[cardIndex].translateState.referenceAlignmentSummary = ""
        cards[cardIndex].translateState.reviewReport = nil
        cards[cardIndex].translateState.reviewSummary = ""
        cards[cardIndex].translateState.flaggedCueCount = 0
        cards[cardIndex].translateState.overrideCount = 0
        cards[cardIndex].translateState.usedReferenceSelection = nil
        if !resumeExistingDraft {
            cards[cardIndex].translateState.completedCueCount = 0
            cards[cardIndex].translateState.totalCueCount = 0
            cards[cardIndex].translateState.resumeCursor = 0
            cards[cardIndex].translateState.draftDocument = nil
            cards[cardIndex].translateState.draftSaveURL = nil
            cards[cardIndex].translateState.translatedDocument = nil
        }

        translationTask = Task { [weak self] in
            guard let self else { return }

            do {
                let sourceDocument = try await Task.detached { [subtitleIOService = self.environment.subtitleIOService] in
                    try await subtitleIOService.loadDocument(for: sourceCandidate, videoURL: selectedVideoURL)
                }.value
                let referenceResolution = await self.resolveReferenceSelection(
                    forCardIndex: cardIndex,
                    videoURL: selectedVideoURL,
                    sourceDocument: sourceDocument
                )
                let sourceLanguage = sourceDocument.language
                let targetLanguage = await MainActor.run { self.cards[cardIndex].language }

                await MainActor.run {
                    self.cards[cardIndex].translateState.totalCueCount = sourceDocument.cues.count
                    self.cards[cardIndex].translateState.jobState = .running
                    self.cards[cardIndex].translateState.statusMessage =
                        referenceResolution.selection == nil
                        ? "Translating \(sourceLanguage.displayName) -> \(targetLanguage.displayName)..."
                        : "Translating \(sourceLanguage.displayName) -> \(targetLanguage.displayName) with QA assist..."
                    self.cards[cardIndex].translateState.referenceWarningMessage = referenceResolution.warning ?? ""
                    self.cards[cardIndex].translateState.usedReferenceSelection = referenceResolution.selection
                    self.cards[cardIndex].translateState.draftDocument = self.buildTranslatedDocument(
                        source: sourceDocument,
                        translatedTexts: initialResults.isEmpty ? Array(repeating: "", count: sourceDocument.cues.count) : initialResults,
                        targetLanguage: targetLanguage
                    )
                    self.refreshPreviewForCurrentState()
                }

                let config = await MainActor.run {
                    TranslationOrchestrator.Config(
                        batchSize: effectiveSettings.translationBatchSize,
                        maxRetries: 2,
                        maxPromptCharacters: 6_500,
                        customInstructions: effectiveSettings.translationCustomInstructions,
                        episodeContext: self.cards[cardIndex].translateState.episodeContext,
                        keepNames: effectiveSettings.translationKeepNames,
                        keepLocations: effectiveSettings.translationKeepLocations,
                        keepBrands: effectiveSettings.translationKeepBrands,
                        maxLinesPerCue: 2,
                        targetCharactersPerLine: 42,
                        qualityProfile: effectiveSettings.translationQualityProfile,
                        passStrategy: effectiveSettings.translationPassStrategy,
                        strictness: effectiveSettings.translationStrictness,
                        referenceSelection: referenceResolution.selection,
                        referenceDocument: referenceResolution.document,
                        referenceOverrideConfidenceThreshold: effectiveSettings.referenceOverrideConfidenceThreshold
                    )
                }

                let orchestrator = TranslationOrchestrator(
                    translationService: translationService,
                    settings: effectiveSettings
                )

                let outcome = try await orchestrator.translate(
                    cues: sourceDocument.cues,
                    from: sourceLanguage,
                    to: targetLanguage,
                    initialResults: initialResults,
                    startIndex: resumeCursor,
                    config: config,
                    controlHandler: { [weak self] in
                        guard let self else { return nil }
                        return await MainActor.run {
                            self.translationPendingControl(forCardIndex: cardIndex)
                        }
                    }
                ) { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.processingProgress = Double(progress.completed) / Double(max(progress.total, 1))
                        self.cards[cardIndex].translateState.completedCueCount = progress.completed
                        self.cards[cardIndex].translateState.totalCueCount = progress.total
                        self.cards[cardIndex].translateState.resumeCursor = progress.completed
                        self.cards[cardIndex].translateState.activeBatchRange = progress.activeBatchRange
                        self.cards[cardIndex].translateState.lastCompletedBatchRange = progress.lastCompletedBatchRange
                        self.cards[cardIndex].translateState.statusMessage = progress.statusMessage
                        self.applyReviewReport(progress.reviewReport, toCardIndex: cardIndex)
                        self.cards[cardIndex].translateState.draftDocument = self.buildTranslatedDocument(
                            source: sourceDocument,
                            translatedTexts: progress.partialResults,
                            targetLanguage: targetLanguage
                        )
                        self.refreshPreviewForCurrentState()
                    }
                }

                await MainActor.run {
                    self.handleTranslationOutcome(
                        outcome,
                        sourceDocument: sourceDocument,
                        targetLanguage: targetLanguage,
                        cardIndex: cardIndex
                    )
                }
            } catch {
                await MainActor.run {
                    if error is CancellationError {
                        self.translationTask = nil
                        self.activeTranslationCardIndex = nil
                        return
                    }
                    self.cards[cardIndex].translateState.jobState = .failed
                    self.cards[cardIndex].translateState.pendingControl = nil
                    self.cards[cardIndex].translateState.activeBatchRange = nil
                    self.cards[cardIndex].translateState.statusMessage = "Translation failed."
                    self.processingProgress = 0
                    self.translationTask = nil
                    self.activeTranslationCardIndex = nil
                    self.fail(error, context: "translateSubtitles")
                }
            }
        }
    }

    private func handleTranslationOutcome(
        _ outcome: TranslationOrchestrator.Outcome,
        sourceDocument: SubtitleDocument,
        targetLanguage: LanguageOption,
        cardIndex: Int
    ) {
        cards[cardIndex].translateState.completedCueCount = outcome.completed
        cards[cardIndex].translateState.totalCueCount = outcome.total
        cards[cardIndex].translateState.resumeCursor = outcome.completed
        cards[cardIndex].translateState.lastCompletedBatchRange = outcome.lastCompletedBatchRange
        cards[cardIndex].translateState.activeBatchRange = nil
        cards[cardIndex].translateState.pendingControl = nil
        applyReviewReport(outcome.reviewReport, toCardIndex: cardIndex)
        let translatedDocument = buildTranslatedDocument(
            source: sourceDocument,
            translatedTexts: outcome.results,
            targetLanguage: targetLanguage
        )

        switch outcome.state {
        case .completed:
            do {
                let savedURL = try saveTranslatedSidecar(translatedDocument)
                cards[cardIndex].translateState.draftDocument = translatedDocument
                cards[cardIndex].translateState.draftSaveURL = savedURL
                cards[cardIndex].translateState.translatedDocument = translatedDocument
                cards[cardIndex].translateState.jobState = .completed
                cards[cardIndex].translateState.statusMessage = "Translation complete."
                processingProgress = 1
                try importSubtitleCandidate(
                    at: savedURL,
                    for: targetLanguage,
                    cardIndex: cardIndex,
                    origin: .llmTranslation,
                    selectImportedCandidate: false
                )
                status("Translation complete. Added a generated \(targetLanguage.displayName) subtitle to Card \(cardIndex + 1).")
            } catch {
                cards[cardIndex].translateState.jobState = .failed
                cards[cardIndex].translateState.statusMessage = "Translation failed while saving."
                fail(error, context: "saveTranslatedSidecar")
            }
        case .paused:
            cards[cardIndex].translateState.draftDocument = translatedDocument
            cards[cardIndex].translateState.translatedDocument = nil
            cards[cardIndex].translateState.jobState = .paused
            cards[cardIndex].translateState.statusMessage = "Paused. Resume when ready."
            processingProgress = Double(outcome.completed) / Double(max(outcome.total, 1))
            status("Paused translation for Card \(cardIndex + 1) after cue \(outcome.completed).")
        case .stopped:
            cards[cardIndex].translateState.draftDocument = translatedDocument
            cards[cardIndex].translateState.translatedDocument = nil
            cards[cardIndex].translateState.jobState = .idle
            cards[cardIndex].translateState.statusMessage = "Stopped. Draft preserved on this card."
            processingProgress = Double(outcome.completed) / Double(max(outcome.total, 1))
            status("Stopped translation for Card \(cardIndex + 1) and preserved the partial draft.")
        case .cancelled:
            clearTranslationDraft(forCardIndex: cardIndex)
            status("Cancelled translation for Card \(cardIndex + 1).")
        }

        refreshPreviewForCurrentState()

        translationTask = nil
        activeTranslationCardIndex = nil
    }

    private func translationPendingControl(forCardIndex cardIndex: Int) -> TranslationPendingControl? {
        guard cards.indices.contains(cardIndex) else { return nil }
        return cards[cardIndex].translateState.pendingControl
    }

    private func resetTranslationState(forCardIndex cardIndex: Int) {
        guard cards.indices.contains(cardIndex) else { return }

        if activeTranslationCardIndex == cardIndex {
            translationTask?.cancel()
            translationTask = nil
            activeTranslationCardIndex = nil
        }
        cards[cardIndex].translateState.jobState = .idle
        cards[cardIndex].translateState.pendingControl = nil
        cards[cardIndex].translateState.completedCueCount = 0
        cards[cardIndex].translateState.totalCueCount = 0
        cards[cardIndex].translateState.resumeCursor = 0
        cards[cardIndex].translateState.activeBatchRange = nil
        cards[cardIndex].translateState.lastCompletedBatchRange = nil
        cards[cardIndex].translateState.draftDocument = nil
        cards[cardIndex].translateState.draftSaveURL = nil
        cards[cardIndex].translateState.translatedDocument = nil
        cards[cardIndex].translateState.referenceWarningMessage = ""
        cards[cardIndex].translateState.referenceAlignmentSummary = ""
        cards[cardIndex].translateState.reviewReport = nil
        cards[cardIndex].translateState.reviewSummary = ""
        cards[cardIndex].translateState.flaggedCueCount = 0
        cards[cardIndex].translateState.overrideCount = 0
        cards[cardIndex].translateState.usedReferenceSelection = nil
        cards[cardIndex].translateState.statusMessage = ""
        processingProgress = 0
    }

    private func clearTranslationDraft(forCardIndex cardIndex: Int) {
        resetTranslationState(forCardIndex: cardIndex)
        refreshPreviewForCurrentState()
    }

    private func applyReviewReport(_ reviewReport: TranslationReviewReport?, toCardIndex cardIndex: Int) {
        guard cards.indices.contains(cardIndex) else { return }
        cards[cardIndex].translateState.reviewReport = reviewReport
        cards[cardIndex].translateState.reviewSummary = reviewReport?.summary ?? ""
        cards[cardIndex].translateState.flaggedCueCount = reviewReport?.flaggedCueCount ?? 0
        cards[cardIndex].translateState.overrideCount = reviewReport?.overrideCount ?? 0
    }

    private func resolveReferenceSelection(
        forCardIndex cardIndex: Int,
        videoURL: URL,
        sourceDocument: SubtitleDocument
    ) async -> (selection: ReferenceSubtitleSelection?, document: SubtitleDocument?, warning: String?) {
        guard cards.indices.contains(cardIndex),
              let candidateID = cards[cardIndex].translateState.referenceCandidateID else {
            return (nil, nil, nil)
        }

        let options = translationReferenceOptions(forCardIndex: cardIndex)
        guard let candidate = options.first(where: { $0.id == candidateID }) else {
            return (nil, nil, "The selected reference subtitle is no longer available. Translation will continue without it.")
        }

        do {
            let referenceDocument = try await Task.detached { [subtitleIOService = self.environment.subtitleIOService] in
                try await subtitleIOService.loadDocument(for: candidate, videoURL: videoURL)
            }.value

            let normalization = SubtitleAligner().normalizeSecondaryToSource(source: sourceDocument, target: referenceDocument)
            let warning = referenceSelectionWarning(normalization: normalization)
            let selection = ReferenceSubtitleSelection(
                candidateID: candidate.id,
                language: referenceDocument.language,
                sourceLabel: candidate.translationSourceLabel,
                confidenceThreshold: providerSettings.referenceOverrideConfidenceThreshold
            )

            cards[cardIndex].translateState.referenceAlignmentSummary = normalization.summaryLine

            if warning?.contains("ignored") == true {
                return (nil, nil, warning)
            }

            return (selection, referenceDocument, warning)
        } catch {
            return (nil, nil, "Failed to load the selected reference subtitle. Translation will continue without it.")
        }
    }

    private func referenceSelectionWarning(normalization: AlignmentNormalizationResult) -> String? {
        if !normalization.isReliable {
            return "Selected reference subtitle looks weakly aligned and will be ignored for QA assist."
        }
        if normalization.report.matchedCueRatio < 0.72 || normalization.report.lowConfidenceCueRatio > 0.18 {
            return "Selected reference subtitle may be a different subtitle version. QA assist will use it cautiously."
        }
        return nil
    }

    @discardableResult
    private func importSubtitleCandidate(
        at url: URL,
        for language: LanguageOption,
        cardIndex: Int,
        origin: SubtitleOriginKind,
        selectImportedCandidate: Bool,
        sourceSearchResult: OpenSubtitleSearchResult? = nil
    ) throws -> SubtitleCandidate {
        let imported = try environment.subtitleIOService.importFallbackSubtitleWithDocument(
            at: url,
            language: language,
            roleOrigin: origin
        )
        let candidate = imported.candidate
        let document = imported.document ?? SubtitleDocument(
            language: candidate.language,
            format: candidate.format,
            origin: candidate.origin,
            sourceLabel: candidate.sourceLabel,
            cues: []
        )
        let profile = SubtitleLanguageProfiler.profile(document: document, targetLanguage: language)
        var signals = sourceSearchResult?.qualitySignals ?? []
        if profile.reviewRequired {
            signals.append(.languageProfileReview(profile.summary))
        }
        let qualityCandidate = candidate.withQuality(
            signals: deduplicatedSignals(signals),
            languageProfile: profile
        )

        updateInventory(with: qualityCandidate)

        let shouldBlockAutoSelection = origin == .openSubtitles && qualityCandidate.reviewRequired
        if selectImportedCandidate && !shouldBlockAutoSelection {
            cards[cardIndex].selectedCandidateID = qualityCandidate.id
            cards[cardIndex].loadedDocument = nil
            loadedSelectionKeys[cardIndex] = nil
            status("Imported \(qualityCandidate.origin.title.lowercased()) subtitle into Card \(cardIndex + 1): \(url.lastPathComponent)")
            resolveCurrentSelections()
        } else {
            status("Added \(qualityCandidate.origin.title.lowercased()) subtitle candidate to Card \(cardIndex + 1): \(url.lastPathComponent)")
        }

        mergedDocumentCache.removeAll()
        return qualityCandidate
    }

    private func deduplicatedSignals(_ signals: [CandidateQualitySignal]) -> [CandidateQualitySignal] {
        var seen: Set<CandidateQualitySignal.Kind> = []
        return signals.filter { signal in
            seen.insert(signal.kind).inserted
        }
    }

    private func updateInventory(with candidate: SubtitleCandidate) {
        let currentVideoURL = inventory?.videoURL ?? selectedVideoURL
        guard let currentVideoURL else { return }

        let filteredCandidates = inventory?.candidates.filter { existingCandidate in
            guard let existingURL = existingCandidate.fileURL, let newURL = candidate.fileURL else {
                return true
            }
            return existingURL.standardizedFileURL != newURL.standardizedFileURL
        } ?? []

        inventory = SubtitleInventory(
            videoURL: currentVideoURL,
            containerName: inventory?.containerName ?? currentVideoURL.pathExtension.lowercased(),
            candidates: filteredCandidates + [candidate],
            bitmapTrackCounts: inventory?.bitmapTrackCounts ?? [:],
            warnings: inventory?.warnings ?? []
        )
    }

    private func buildTranslatedDocument(
        source: SubtitleDocument,
        translatedTexts: [String],
        targetLanguage: LanguageOption
    ) -> SubtitleDocument {
        let cues = source.cues.enumerated().map { index, cue in
            let translatedText = index < translatedTexts.count ? translatedTexts[index] : ""
            return SubtitleCue(
                id: cue.id,
                startMilliseconds: cue.startMilliseconds,
                endMilliseconds: cue.endMilliseconds,
                rawText: translatedText,
                plainText: translatedText
            )
        }

        return SubtitleDocument(
            language: targetLanguage,
            format: exportFormat,
            origin: .llmTranslation,
            sourceLabel: "Translated (\(source.language.displayName) -> \(targetLanguage.displayName))",
            cues: cues
        )
    }

    private func saveTranslatedSidecar(_ document: SubtitleDocument) throws -> URL {
        guard let selectedVideoURL else {
            throw WorkflowError.runtime("No selected video is available for saving translated subtitles.")
        }

        let stem = selectedVideoURL.deletingPathExtension().lastPathComponent
        let destination = selectedVideoURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem).\(document.language.code)\(SubtitleSourceKind.llmTranslation.fileSuffix).\(exportFormat.fileExtension)")
        let finalURL = uniqueOutputURL(base: destination)
        try environment.subtitleIOService.saveDocument(document, to: finalURL)
        return finalURL
    }

    private func normalizeTranslationSources() {
        for cardIndex in cards.indices {
            let options = translationSourceOptions(forCardIndex: cardIndex)
            let referenceOptions = translationReferenceOptions(forCardIndex: cardIndex)

            if let selectedSource = cards[cardIndex].translateState.sourceCandidateID,
               !options.contains(where: { $0.id == selectedSource }) {
                cards[cardIndex].translateState.sourceCandidateID = effectiveTranslationSourceCandidateID(
                    forCardIndex: cardIndex,
                    sourceOptions: options
                )
            }

            if cards[cardIndex].translateState.sourceCandidateID == nil {
                cards[cardIndex].translateState.sourceCandidateID = effectiveTranslationSourceCandidateID(
                    forCardIndex: cardIndex,
                    sourceOptions: options
                )
            }

            if let selectedReference = cards[cardIndex].translateState.referenceCandidateID,
               !referenceOptions.contains(where: { $0.id == selectedReference }) {
                cards[cardIndex].translateState.referenceCandidateID = nil
            }
        }
    }

    private func resetSelectionState(keepVideo: Bool) {
        inspectionReport = nil
        inventory = nil
        cards = Self.defaultCards(lastUsedProviderPresetID: providerSettings.lastUsedProviderPresetID)
        previewState = PreviewMergeState()
        previewMode = .none
        mergedDocument = nil
        qualityReport = nil
        isQualityEvaluationPending = false
        qualityOverrideAcknowledged = false
        lastSavedSidecarURL = nil
        lastEmbeddedOutputURL = nil
        isProcessing = false
        processingLabel = ""
        processingProgress = 0
        mergedDocumentCache.removeAll()
        loadedSelectionKeys = [nil, nil]
        currentResolutionTask?.cancel()
        mergePreviewTask?.cancel()
        translationTask?.cancel()
        currentResolutionTask = nil
        translationTask = nil
        activeTranslationCardIndex = nil
        if !keepVideo {
            selectedVideoURL = nil
        }
    }

    private func uniqueOutputURL(base: URL) -> URL {
        guard FileManager.default.fileExists(atPath: base.path) else { return base }

        let directory = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension

        for index in 1...99 {
            let candidate = directory.appendingPathComponent("\(stem)-\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(6)).\(ext)")
    }

    private func bitmapOnlyMessage(for language: LanguageOption) -> String? {
        guard let availability = languageAvailability.first(where: { $0.language == language }),
              availability.hasBitmapOnlyCandidates else {
            return nil
        }
        return "Only image-based subtitles are available for \(language.displayName). OCR is not implemented yet."
    }

    private func selectionKey(for candidate: SubtitleCandidate?, videoURL: URL) -> String? {
        guard let candidate else { return nil }
        switch candidate.locator {
        case .file(let url):
            return "file:\(url.standardizedFileURL.path)"
        case .embedded(let trackIndex):
            return "embedded:\(videoURL.standardizedFileURL.path)#\(trackIndex)"
        case .generated:
            return "generated:\(candidate.id)"
        }
    }

    private func remoteExtractionNote(for videoURL: URL) -> String {
        guard videoURL.path.hasPrefix("/Volumes/") else { return "" }

        let byteCount = (try? videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formattedSize = byteCount > 0 ? ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) : "remote"
        return " This file is on a mounted volume (\(formattedSize)); embedded extraction may scan the full file and take several minutes."
    }

    private func status(_ line: String) {
        lastError = nil
        statusLines.insert(WorkflowLogEntry(message: line, kind: .info), at: 0)
    }

    private func fail(_ message: String) {
        let displayMessage = message.isEmpty ? "<empty error message>" : message
        lastError = displayMessage
        statusLines.insert(WorkflowLogEntry(message: "Error: \(displayMessage)", kind: .error), at: 0)
    }

    private func fail(_ error: Error, context: String) {
        let message = "\(context): \(error.localizedDescription)"
        lastError = message
        statusLines.insert(WorkflowLogEntry(message: "Error: \(message)", kind: .error), at: 0)
    }

    private var currentMergeCacheKey: String {
        "\(cards[0].selectedCandidateID ?? "nil")-\(cards[1].selectedCandidateID ?? "nil")"
    }
}

private extension SubtitleFormatKind {
    var allowedContentTypes: [UTType] {
        switch self {
        case .srt, .ass, .vtt:
            return [.plainText]
        case .unknown:
            return [.data]
        }
    }
}

private extension Array {
    func uniqued<T: Hashable>(by keyPath: KeyPath<Element, T>) -> [Element] {
        var seen = Set<T>()
        return filter { element in
            seen.insert(element[keyPath: keyPath]).inserted
        }
    }
}
