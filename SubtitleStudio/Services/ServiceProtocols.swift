import Foundation

protocol MediaInspectionServicing: Sendable {
    func inspect(videoURL: URL) async throws -> VideoInspectionReport
}

protocol SubtitleInventoryServicing: Sendable {
    func buildInventory(from report: VideoInspectionReport) -> SubtitleInventory
}

protocol SubtitleDocumentIOServicing: Sendable {
    func loadDocument(for candidate: SubtitleCandidate, videoURL: URL) async throws -> SubtitleDocument
    func extractorKind(for candidate: SubtitleCandidate, videoURL: URL) -> EmbeddedSubtitleExtractorKind?
    func importFallbackSubtitle(at url: URL, language: LanguageOption, roleOrigin: SubtitleOriginKind) throws -> SubtitleCandidate
    func importFallbackSubtitleWithDocument(at url: URL, language: LanguageOption, roleOrigin: SubtitleOriginKind) throws -> ImportedSubtitleCandidate
    func saveDocument(_ document: SubtitleDocument, to url: URL) throws
}

extension SubtitleDocumentIOServicing {
    func importFallbackSubtitleWithDocument(at url: URL, language: LanguageOption, roleOrigin: SubtitleOriginKind) throws -> ImportedSubtitleCandidate {
        ImportedSubtitleCandidate(
            candidate: try importFallbackSubtitle(at: url, language: language, roleOrigin: roleOrigin),
            document: nil
        )
    }
}

protocol SubtitleMergingServicing: Sendable {
    func merge(
        source: SubtitleDocument,
        target: SubtitleDocument,
        outputFormat: SubtitleFormatKind,
        vadResult: VADArbitrationResult?,
        alignmentReport: AlignmentReport?,
        onSegment: ((MergeSegment) -> Void)?,
        onPage: (([BilingualCue], Int, Int?) -> Void)?
    ) -> MergedSubtitleDocument
}

protocol VADServicing: Sendable {
    func classifyCues(in document: SubtitleDocument, trackTitle: String?) -> [CueKind]
    func analyze(
        videoURL: URL,
        source: SubtitleDocument,
        target: SubtitleDocument,
        audioTrackIndex: Int
    ) async throws -> VADArbitrationResult
}

protocol SubtitleQualityScoringServicing: Sendable {
    func evaluate(
        source: SubtitleDocument,
        candidate: SubtitleDocument,
        targetLanguage: LanguageOption,
        alignmentReport: AlignmentReport?
    ) -> SubtitleQualityReport
}

protocol SubtitleExportServicing: Sendable {
    func export(_ merged: MergedSubtitleDocument, to destinationURL: URL) throws
}

protocol MKVEmbeddingServicing: Sendable {
    func embedCapability(
        for inspectionReport: VideoInspectionReport,
        merged: MergedSubtitleDocument,
        destinationMode: EmbedDestinationMode
    ) -> EmbeddedExportCapability
    func embed(
        merged: MergedSubtitleDocument,
        inspectionReport: VideoInspectionReport,
        destinationMode: EmbedDestinationMode
    ) async throws -> URL
}

protocol CredentialStore: Sendable {
    func save(_ value: String, account: String) throws
    func load(account: String) throws -> String?
}

protocol OpenSubtitlesServicing: Sendable {
    func validateConfiguration(username: String) throws
    func searchSubtitles(videoHash: String, languages: [String], videoURL: URL?) async throws -> OpenSubtitleSearchResponse
    func downloadSubtitle(subtitleID: String) async throws -> URL
}

protocol SubtitlePreAlignmentServicing: Sendable {
    func preAlign(
        native: SubtitleDocument,
        reference: SubtitleDocument,
        vadResult: VADArbitrationResult?
    ) async throws -> PreAlignmentOutcome
}

protocol TranslationServicing: Sendable {
    var kind: TranslationProviderKind { get }
    var capabilities: TranslationProviderCapabilities { get }
    func validateConfiguration(settings: ProviderSettings) throws
    func translate(
        _ request: TranslationRequest,
        settings: ProviderSettings
    ) async throws -> TranslationResponse
}
