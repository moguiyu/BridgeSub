import Foundation

struct AppEnvironment {
    let toolRegistry: MediaToolRegistry
    let mediaInspectionService: any MediaInspectionServicing
    let inventoryService: any SubtitleInventoryServicing
    let subtitleIOService: any SubtitleDocumentIOServicing
    let mergeService: any SubtitleMergingServicing
    let qualityService: any SubtitleQualityScoringServicing
    let exportService: any SubtitleExportServicing
    let mkvEmbeddingService: any MKVEmbeddingServicing
    let credentialStore: any CredentialStore
    let openSubtitlesService: any OpenSubtitlesServicing
    let translationProviders: [TranslationProviderKind: any TranslationServicing]

    @MainActor
    static let live: AppEnvironment = {
        let processRunner = ProcessRunner()
        let credentialStore = KeychainCredentialStore(serviceName: "SubtitleStudio")
        let toolRegistry = MediaToolRegistry()

        return AppEnvironment(
            toolRegistry: toolRegistry,
            mediaInspectionService: FFprobeMediaInspectionService(
                processRunner: processRunner,
                toolRegistry: toolRegistry
            ),
            inventoryService: SubtitleInventoryService(),
            subtitleIOService: SubtitleDocumentIOService(
                processRunner: processRunner,
                toolRegistry: toolRegistry
            ),
            mergeService: SubtitleMergeService(),
            qualityService: SubtitleQualityService(),
            exportService: SubtitleExportService(),
            mkvEmbeddingService: MKVEmbeddingService(
                processRunner: processRunner,
                exportService: SubtitleExportService(),
                toolRegistry: toolRegistry
            ),
            credentialStore: credentialStore,
            openSubtitlesService: OpenSubtitlesRESTClient(
                session: .shared,
                credentialStore: credentialStore
            ),
            translationProviders: [
                .ollama: OllamaTranslationService(credentialStore: credentialStore),
                .openAICompatible: OpenAICompatibleTranslationService(credentialStore: credentialStore)
            ]
        )
    }()
}
