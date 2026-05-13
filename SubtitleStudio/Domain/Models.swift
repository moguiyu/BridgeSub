import Foundation

enum SubtitleFormatKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case srt
    case ass
    case vtt
    case unknown

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .ass: return "ass"
        case .vtt: return "vtt"
        case .unknown: return "txt"
        }
    }
}

enum SubtitleOriginKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case embedded
    case localFile
    case openSubtitles
    case llmTranslation
    case mergedOutput
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embedded: return "Embedded"
        case .localFile: return "Sidecar"
        case .openSubtitles: return "OpenSubtitles"
        case .llmTranslation: return "LLM"
        case .mergedOutput: return "Merged"
        case .unknown: return "Unknown"
        }
    }
}

enum CueKind: String, Codable, Sendable {
    case dialogue
    case sdh
    case forcedNarrative
    case ad
    case unknown
}

struct CueVADScore: Equatable, Sendable {
    let cueID: Int
    let speechOverlapRatio: Double
    let startDeltaMilliseconds: Int?
    let endDeltaMilliseconds: Int?
    let hasSpeech: Bool

    static let none = CueVADScore(
        cueID: -1, speechOverlapRatio: 0,
        startDeltaMilliseconds: nil, endDeltaMilliseconds: nil,
        hasSpeech: false
    )
}

struct VADSpeechSegment: Equatable, Sendable {
    let startMilliseconds: Int
    let endMilliseconds: Int
    let confidence: Double
}

struct VADArbitrationResult: Equatable, Sendable {
    let sourceScores: [Int: CueVADScore]
    let targetScores: [Int: CueVADScore]
    let speechSegments: [VADSpeechSegment]
    let elapsedSeconds: TimeInterval

    var sourceAverageScore: Double {
        guard !sourceScores.isEmpty else { return 0 }
        return sourceScores.values.map(\.speechOverlapRatio).reduce(0, +) / Double(sourceScores.count)
    }

    var targetAverageScore: Double {
        guard !targetScores.isEmpty else { return 0 }
        return targetScores.values.map(\.speechOverlapRatio).reduce(0, +) / Double(targetScores.count)
    }

    func masterSide(for sourceCueID: Int, targetCueID: Int?) -> VADMasterSide {
        let s = sourceScores[sourceCueID]?.speechOverlapRatio ?? 0
        let t = targetCueID.flatMap { targetScores[$0]?.speechOverlapRatio } ?? 0
        if s > t + 0.15 { return .source }
        if t > s + 0.15 { return .target }
        return sourceAverageScore >= targetAverageScore ? .source : .target
    }

    static let empty = VADArbitrationResult(
        sourceScores: [:], targetScores: [:],
        speechSegments: [], elapsedSeconds: 0
    )
}

enum VADMasterSide: String, Sendable {
    case source
    case target
}

struct AudioTrackCandidate: Identifiable, Equatable, Sendable {
    let id: Int
    let index: Int
    let codecName: String
    let languageCode: String?
    let resolvedLanguage: LanguageOption?
    let channels: Int
    let bitrate: Int?
    let isRecommended: Bool

    var displayLabel: String {
        let lang = resolvedLanguage?.displayName ?? (languageCode ?? "Unknown")
        let chan = channels == 1 ? "mono" : (channels == 2 ? "stereo" : "\(channels)ch")
        var label = "\(lang) · \(codecName) · \(chan)"
        if isRecommended { label += " · Recommended" }
        return label
    }

    static func recommended(from streams: [AudioStream], preferredLanguage: LanguageOption?) -> AudioTrackCandidate? {
        let scored = streams.map { stream in
            var score = 0
            if stream.resolvedLanguage == preferredLanguage { score += 100 }
            let c = stream.codecName.lowercased()
            if c.contains("ac3") || c.contains("eac3") { score += 50 }
            else if c.contains("aac") { score += 40 }
            else if c.contains("truehd") || c.contains("dts-hd") { score += 10 }
            if stream.channels <= 2 { score += 20 }
            return (stream, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        let s = best.0
        return AudioTrackCandidate(
            id: s.id, index: s.index, codecName: s.codecName,
            languageCode: s.languageCode, resolvedLanguage: s.resolvedLanguage,
            channels: s.channels, bitrate: s.bitrate, isRecommended: true
        )
    }
}

enum RemoteMediaPolicy {
    static let largeRemoteMKVThresholdBytes = 8 * 1_024 * 1_024 * 1_024

    static func isLargeRemoteMKV(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "mkv",
              url.path.hasPrefix("/Volumes/") else {
            return false
        }

        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return true
        }
        return fileSize >= largeRemoteMKVThresholdBytes
    }
}

enum ExportMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case externalOnly
    case externalAndTryEmbeddedMKV

    var id: String { rawValue }

    var title: String {
        switch self {
        case .externalOnly:
            return "Sidecar only"
        case .externalAndTryEmbeddedMKV:
            return "Sidecar + embed into video"
        }
    }
}

enum EmbedDestinationMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case createNewFile
    case replaceOriginal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .createNewFile:
            return "Create new file"
        case .replaceOriginal:
            return "Replace original"
        }
    }
}

enum TranslationProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Local Ollama"
        case .openAICompatible: return "OpenAI Compatible"
        }
    }
}

enum TranslationProviderPresetID: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama
    case openAI
    case deepSeek
    case openRouter
    case siliconFlow
    case groq
    case togetherAI
    case fireworksAI
    case xAI
    case customOpenAICompatible

    var id: String { rawValue }

    var descriptor: TranslationProviderPresetDescriptor {
        switch self {
        case .ollama:
            return TranslationProviderPresetDescriptor(
                id: self,
                displayName: "Ollama",
                transportKind: .ollama,
                defaultBaseURL: "http://localhost:11434",
                defaultModel: "qwen3:30b",
                keychainAccount: nil,
                requiresAPIKey: false,
                supportsOpenAICompatibleToggle: true
            )
        case .openAI:
            return TranslationProviderPresetDescriptor(
                id: self,
                displayName: "OpenAI",
                transportKind: .openAICompatible,
                defaultBaseURL: "https://api.openai.com/v1",
                defaultModel: "gpt-5-mini",
                keychainAccount: "openai.apiKey",
                requiresAPIKey: true,
                supportsOpenAICompatibleToggle: false
            )
        case .deepSeek:
            return TranslationProviderPresetDescriptor(
                id: self,
                displayName: "DeepSeek",
                transportKind: .openAICompatible,
                defaultBaseURL: "https://api.deepseek.com/v1",
                defaultModel: "deepseek-chat",
                keychainAccount: "deepseek.apiKey",
                requiresAPIKey: true,
                supportsOpenAICompatibleToggle: false
            )
        case .openRouter:
            return TranslationProviderPresetDescriptor(
                id: self,
                displayName: "OpenRouter",
                transportKind: .openAICompatible,
                defaultBaseURL: "https://openrouter.ai/api/v1",
                defaultModel: "openai/gpt-5-mini",
                keychainAccount: "openrouter.apiKey",
                requiresAPIKey: true,
                supportsOpenAICompatibleToggle: false
            )
        case .siliconFlow:
            return TranslationProviderPresetDescriptor(
                id: self,
                displayName: "SiliconFlow",
                transportKind: .openAICompatible,
                defaultBaseURL: "https://api.siliconflow.cn/v1",
                defaultModel: "Qwen/Qwen3-32B",
                keychainAccount: "siliconflow.apiKey",
                requiresAPIKey: true,
                supportsOpenAICompatibleToggle: false
            )
        case .groq:
            return TranslationProviderPresetDescriptor(
                id: self,
                displayName: "Groq",
                transportKind: .openAICompatible,
                defaultBaseURL: "https://api.groq.com/openai/v1",
                defaultModel: "llama-3.3-70b-versatile",
                keychainAccount: "groq.apiKey",
                requiresAPIKey: true,
                supportsOpenAICompatibleToggle: false
            )
        case .togetherAI:
            return TranslationProviderPresetDescriptor(
                id: self,
                displayName: "Together AI",
                transportKind: .openAICompatible,
                defaultBaseURL: "https://api.together.xyz/v1",
                defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
                keychainAccount: "together.apiKey",
                requiresAPIKey: true,
                supportsOpenAICompatibleToggle: false
            )
        case .fireworksAI:
            return TranslationProviderPresetDescriptor(
                id: self,
                displayName: "Fireworks AI",
                transportKind: .openAICompatible,
                defaultBaseURL: "https://api.fireworks.ai/inference/v1",
                defaultModel: "accounts/fireworks/models/llama-v3p1-70b-instruct",
                keychainAccount: "fireworks.apiKey",
                requiresAPIKey: true,
                supportsOpenAICompatibleToggle: false
            )
        case .xAI:
            return TranslationProviderPresetDescriptor(
                id: self,
                displayName: "xAI",
                transportKind: .openAICompatible,
                defaultBaseURL: "https://api.x.ai/v1",
                defaultModel: "grok-3-mini",
                keychainAccount: "xai.apiKey",
                requiresAPIKey: true,
                supportsOpenAICompatibleToggle: false
            )
        case .customOpenAICompatible:
            return TranslationProviderPresetDescriptor(
                id: self,
                displayName: "Custom OpenAI-Compatible",
                transportKind: .openAICompatible,
                defaultBaseURL: "https://api.example.com/v1",
                defaultModel: "model-name",
                keychainAccount: "customOpenAICompatible.apiKey",
                requiresAPIKey: true,
                supportsOpenAICompatibleToggle: false
            )
        }
    }
}

struct TranslationProviderPresetDescriptor: Equatable, Sendable {
    let id: TranslationProviderPresetID
    let displayName: String
    let transportKind: TranslationProviderKind
    let defaultBaseURL: String
    let defaultModel: String
    let keychainAccount: String?
    let requiresAPIKey: Bool
    let supportsOpenAICompatibleToggle: Bool
}

struct TranslationProviderPresetConfiguration: Equatable, Codable, Identifiable, Sendable {
    let id: TranslationProviderPresetID
    var baseURL: String
    var model: String
    var useOpenAICompatibleEndpoint: Bool

    var descriptor: TranslationProviderPresetDescriptor {
        id.descriptor
    }

    var displayName: String {
        descriptor.displayName
    }

    var transportKind: TranslationProviderKind {
        descriptor.transportKind
    }

    static func defaults(for id: TranslationProviderPresetID) -> TranslationProviderPresetConfiguration {
        let descriptor = id.descriptor
        return TranslationProviderPresetConfiguration(
            id: id,
            baseURL: descriptor.defaultBaseURL,
            model: descriptor.defaultModel,
            useOpenAICompatibleEndpoint: false
        )
    }
}

enum SubtitleDecision: String, Codable, Sendable {
    case accept
    case review
    case reject
}

enum CueAlignmentStatus: String, Codable, Sendable {
    case matched
    case lowConfidence
    case unmatched
}

enum WorkflowPhase: String, Codable, Sendable {
    case idle
    case videoSelected
    case inspected
    case languagesChosen
    case candidatesResolved
    case targetQualityChecked
    case previewReady
    case exportReady
}

enum SubtitleProcessingOption: String, CaseIterable, Identifiable, Sendable {
    case useAvailable
    case searchOnline
    case translateWithLLM

    var id: String { rawValue }

    var title: String {
        switch self {
        case .useAvailable: return "Use Available"
        case .searchOnline: return "Search Online"
        case .translateWithLLM: return "Translate with LLM"
        }
    }
}

enum SubtitleSourceKind: String, Codable, Sendable {
    case embedded
    case sidecar
    case openSubtitles
    case llmTranslation

    var fileSuffix: String {
        switch self {
        case .embedded: return ".emb"
        case .sidecar: return ""
        case .openSubtitles: return ".os"
        case .llmTranslation: return ".tr"
        }
    }
}

enum TranslationJobState: String, Codable, Sendable {
    case idle
    case preparing
    case running
    case pauseRequested
    case paused
    case stopRequested
    case cancelling
    case completed
    case failed

    var isActive: Bool {
        switch self {
        case .preparing, .running, .pauseRequested, .stopRequested, .cancelling:
            return true
        case .idle, .paused, .completed, .failed:
            return false
        }
    }
}

enum TranslationPendingControl: String, Codable, Sendable {
    case pause
    case stop
    case cancel
}

enum ContentType: String, CaseIterable, Codable, Identifiable, Sendable {
    case drama
    case comedy
    case actionThriller
    case documentary
    case childrens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drama: return "Drama / General"
        case .comedy: return "Comedy"
        case .actionThriller: return "Action / Thriller"
        case .documentary: return "Documentary"
        case .childrens: return "Children's"
        }
    }
}

enum TranslationPassStrategy: String, CaseIterable, Codable, Identifiable, Sendable {
    case draftOnly
    case reviewAndRewrite
    case qualityFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draftOnly:
            return "Draft only"
        case .reviewAndRewrite:
            return "Review + rewrite"
        case .qualityFirst:
            return "Quality first"
        }
    }
}

struct TranslationBatchRange: Equatable, Codable, Sendable {
    let startIndex: Int
    let endIndex: Int

    var completedCount: Int {
        max(0, endIndex - startIndex + 1)
    }
}

enum TranslationMessageRole: String, Codable, Sendable {
    case system
    case user
}

enum TranslationPassKind: String, Codable, Sendable {
    case draft
    case critique
    case rewrite
}

struct TranslationMessage: Equatable, Sendable {
    let role: TranslationMessageRole
    let content: String
}

enum TranslationCueFindingKind: String, Codable, Sendable {
    case semanticDrift
    case idiomLoss
    case namePreservation
    case registerMismatch
    case subtitleFit
    case referenceConflict
    case culturalMismatch
}

enum TranslationCueFindingSeverity: String, Codable, Sendable {
    case minor
    case major
    case critical
}

enum ReferenceConflictDecision: String, Codable, Sendable {
    case keepSource
    case supportReference
    case overrideWithReference
    case ignoreReference
}

struct TranslationPromptPolicy: Equatable, Sendable {
    let baseRole: String
    let hardRules: [String]
    let contentNotes: [String]
    let advancedInstructions: String
}

struct ReferenceSubtitleSelection: Equatable, Codable, Sendable {
    let candidateID: String
    let language: LanguageOption
    let sourceLabel: String
    let confidenceThreshold: Double
}

struct TranslationCueFinding: Equatable, Codable, Sendable {
    let index: Int
    let severity: TranslationCueFindingSeverity
    let kind: TranslationCueFindingKind
    let message: String
    let suggestedTranslation: String?
    let referenceDecision: ReferenceConflictDecision
    let confidence: Double

    var isReferenceOverride: Bool {
        referenceDecision == .overrideWithReference
    }
}

struct TranslationReviewReport: Equatable, Codable, Sendable {
    let summary: String
    let findings: [TranslationCueFinding]

    var flaggedCueCount: Int {
        Set(findings.map(\.index)).count
    }

    var overrideCount: Int {
        findings.filter(\.isReferenceOverride).count
    }
}

enum TranslationResponseFormat: Equatable, Sendable {
    case plainText
    case jsonObject(schemaName: String)
}

struct TranslationRequest: Equatable, Sendable {
    let passKind: TranslationPassKind
    let messages: [TranslationMessage]
    let responseFormat: TranslationResponseFormat
}

struct TranslationResponse: Equatable, Sendable {
    let content: String
    let usedStructuredOutput: Bool
}

struct TranslationProviderCapabilities: Equatable, Sendable {
    var supportsStructuredOutput: Bool = false
    var supportsStreamingProgress: Bool = false
    var supportsImmediateCancellation: Bool = false
    var supportsPromptCacheHints: Bool = false
    var contextWindowTokens: Int? = nil
}

struct TranslationBrief: Equatable, Sendable {
    let instructions: String
    let recurringTerms: [String]
    let registerSummary: String
    let mediaTitle: String?
    let mediaYear: Int?

    init(
        instructions: String,
        recurringTerms: [String],
        registerSummary: String,
        mediaTitle: String? = nil,
        mediaYear: Int? = nil
    ) {
        self.instructions = instructions
        self.recurringTerms = recurringTerms
        self.registerSummary = registerSummary
        self.mediaTitle = mediaTitle
        self.mediaYear = mediaYear
    }

    var hasContent: Bool {
        !instructions.isEmpty
            || !recurringTerms.isEmpty
            || !registerSummary.isEmpty
            || (mediaTitle?.isEmpty == false)
    }
}

enum SinglePassPreference: String, Codable, Sendable {
    case auto
    case force
    case disable
}

struct PreAlignmentOutcome: Equatable, Sendable {
    let alignedOriginal: SubtitleDocument
    let alignedReference: SubtitleDocument
    let confidenceScores: [Int: Double]
    let appliedOffsetMs: Int
    let usedVAD: Bool

    var matchedCueCount: Int {
        confidenceScores.values.filter { $0 >= 0.58 }.count
    }

    var lowConfidenceCueCount: Int {
        confidenceScores.values.filter { $0 > 0 && $0 < 0.58 }.count
    }

    var averageConfidence: Double {
        guard !confidenceScores.isEmpty else { return 0 }
        return confidenceScores.values.reduce(0, +) / Double(confidenceScores.count)
    }
}

struct DualReferenceSource: Equatable, Sendable {
    let primary: SubtitleDocument
    let secondary: SubtitleDocument
    let primaryLabel: String
    let secondaryLabel: String
    let outcome: PreAlignmentOutcome?
    let confidenceThreshold: Double

    init(
        primary: SubtitleDocument,
        secondary: SubtitleDocument,
        primaryLabel: String,
        secondaryLabel: String,
        outcome: PreAlignmentOutcome? = nil,
        confidenceThreshold: Double = 0.82
    ) {
        self.primary = primary
        self.secondary = secondary
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
        self.outcome = outcome
        self.confidenceThreshold = confidenceThreshold
    }
}

enum PreAlignmentState: Equatable, Sendable {
    case idle
    case running
    case completed(PreAlignmentOutcome)
    case failed(String)
}

struct TranslateState: Equatable, Sendable {
    var providerPresetID: TranslationProviderPresetID = .ollama
    var sourceCandidateID: String?
    var referenceCandidateID: String?
    var secondaryReferenceCandidateID: String?
    var mediaTitle: String = ""
    var mediaYear: Int?
    var instructions: String = ""
    var jobState: TranslationJobState = .idle
    var completedCueCount: Int = 0
    var totalCueCount: Int = 0
    var resumeCursor: Int = 0
    var activeBatchRange: TranslationBatchRange?
    var lastCompletedBatchRange: TranslationBatchRange?
    var pendingControl: TranslationPendingControl?
    var draftDocument: SubtitleDocument?
    var draftSaveURL: URL?
    var translatedDocument: SubtitleDocument?
    var referenceWarningMessage: String = ""
    var referenceAlignmentSummary: String = ""
    var preAlignmentState: PreAlignmentState = .idle
    var preAlignmentSummary: String = ""
    var reviewReport: TranslationReviewReport?
    var reviewSummary: String = ""
    var flaggedCueCount: Int = 0
    var overrideCount: Int = 0
    var usedReferenceSelection: ReferenceSubtitleSelection?
    var statusMessage: String = ""

    var isTranslating: Bool {
        jobState.isActive
    }

    var canResume: Bool {
        let hasRemainingWork = totalCueCount > 0 && resumeCursor < totalCueCount
        return hasRemainingWork && draftDocument != nil && !jobState.isActive
    }
}

struct CardState: Equatable, Sendable {
    var language: LanguageOption = .defaultSource
    var processingOption: SubtitleProcessingOption = .useAvailable
    var selectedCandidateID: String?
    var loadedDocument: SubtitleDocument?
    var searchResults: [OpenSubtitleSearchResult] = []
    var searchMessage: String?
    var translateState: TranslateState = TranslateState()
}

enum CandidateQualitySeverity: String, Codable, Sendable {
    case positive
    case info
    case review
    case warning
}

struct CandidateQualitySignal: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hashMatch
        case trusted
        case hearingImpaired
        case forcedOnly
        case aiTranslated
        case machineTranslated
        case bilingualHint
        case languageProfileReview
        case review
    }

    let kind: Kind
    let label: String
    let explanation: String
    let severity: CandidateQualitySeverity

    var id: String { kind.rawValue }

    static let hashMatch = CandidateQualitySignal(
        kind: .hashMatch,
        label: "Hash match",
        explanation: "Likely synced to this exact video file.",
        severity: .positive
    )
    static let trusted = CandidateQualitySignal(
        kind: .trusted,
        label: "Trusted",
        explanation: "Uploaded by a trusted OpenSubtitles source.",
        severity: .positive
    )
    static let hearingImpaired = CandidateQualitySignal(
        kind: .hearingImpaired,
        label: "HI / Hearing impaired",
        explanation: "May include sound cues or speaker descriptions, such as [door opens].",
        severity: .review
    )
    static let forcedOnly = CandidateQualitySignal(
        kind: .forcedOnly,
        label: "Forced only",
        explanation: "Likely contains only foreign-language dialogue, not full subtitles.",
        severity: .warning
    )
    static let aiTranslated = CandidateQualitySignal(
        kind: .aiTranslated,
        label: "AI translated",
        explanation: "Translated by an AI system; usable candidates still need review.",
        severity: .review
    )
    static let machineTranslated = CandidateQualitySignal(
        kind: .machineTranslated,
        label: "MT / Machine translated",
        explanation: "Machine-translated by an older or automatic translation system; usually lower quality than human or AI-reviewed subtitles.",
        severity: .review
    )
    static let bilingualHint = CandidateQualitySignal(
        kind: .bilingualHint,
        label: "Bilingual?",
        explanation: "Metadata or filename suggests multiple languages, such as zh+fr, dual, multi, bilingual, vostfr, or Chinese bilingual.",
        severity: .warning
    )
    static func languageProfileReview(_ explanation: String) -> CandidateQualitySignal {
        CandidateQualitySignal(
            kind: .languageProfileReview,
            label: "Review",
            explanation: explanation,
            severity: .warning
        )
    }
    static let review = CandidateQualitySignal(
        kind: .review,
        label: "Review",
        explanation: "One or more quality signals suggest this subtitle should be checked before merging.",
        severity: .review
    )
}

struct SubtitleLanguageProfile: Equatable, Codable, Sendable {
    let previewLines: [String]
    let detectedDescription: String
    let targetCoverage: Double
    let latinLeakRatio: Double
    let mixedCueRatio: Double
    let confidence: Double
    let isLikelyBilingual: Bool
    let isLikelyWrongLanguage: Bool
    let warnings: [String]

    var reviewRequired: Bool {
        isLikelyBilingual || isLikelyWrongLanguage || confidence < 0.45
    }

    var summary: String {
        if isLikelyBilingual {
            return "Likely bilingual: \(detectedDescription)"
        }
        if isLikelyWrongLanguage {
            return "Wrong-language risk: \(detectedDescription)"
        }
        if confidence < 0.45 {
            return "Review: sample is too short to judge confidently."
        }
        return "Looks single-language: \(detectedDescription)"
    }
}

enum SubtitleLanguageProfiler {
    static func profile(document: SubtitleDocument, targetLanguage: LanguageOption) -> SubtitleLanguageProfile {
        let normalizedLines = document.cues
            .map { $0.plainText.normalizedSubtitleText }
            .filter { !$0.isEmpty }
        let previewLines = Array(normalizedLines.prefix(5))
        let sample = normalizedLines.prefix(160).joined(separator: " ")

        guard !sample.isEmpty else {
            return SubtitleLanguageProfile(
                previewLines: [],
                detectedDescription: "No readable subtitle text",
                targetCoverage: 0,
                latinLeakRatio: 1,
                mixedCueRatio: 0,
                confidence: 0,
                isLikelyBilingual: false,
                isLikelyWrongLanguage: true,
                warnings: ["Subtitle has no readable text."]
            )
        }

        let hanCount = sample.unicodeScalars.filter { 0x4E00...0x9FFF ~= $0.value }.count
        let latinCount = sample.unicodeScalars.filter(\.isLatinLetter).count
        let languageChars = max(hanCount + latinCount, 1)
        let targetCoverage: Double
        let latinLeakRatio: Double
        if targetLanguage.code == LanguageOption.zhHans.code {
            targetCoverage = Double(hanCount) / Double(languageChars)
            latinLeakRatio = Double(latinCount) / Double(languageChars)
        } else {
            targetCoverage = 1
            latinLeakRatio = 0
        }

        let inspectedLines = Array(normalizedLines.prefix(80))
        let mixedCueCount = inspectedLines.filter { line in
            let han = line.unicodeScalars.filter { 0x4E00...0x9FFF ~= $0.value }.count
            let latin = line.unicodeScalars.filter(\.isLatinLetter).count
            return han > 0 && latin >= 4
        }.count
        let mixedCueRatio = Double(mixedCueCount) / Double(max(inspectedLines.count, 1))
        let frenchHintCount = frenchHintCount(in: sample)
        let sampleIsShort = inspectedLines.count < 5 || languageChars < 12

        let likelyBilingual = targetLanguage.code == LanguageOption.zhHans.code &&
            hanCount >= 8 &&
            latinCount >= 20 &&
            (latinLeakRatio >= 0.18 || mixedCueRatio >= 0.15 || frenchHintCount >= 2)
        let likelyWrongLanguage = targetLanguage.code == LanguageOption.zhHans.code &&
            hanCount < 8 &&
            latinLeakRatio >= 0.65 &&
            !sampleIsShort

        let confidence: Double
        if sampleIsShort {
            confidence = 0.35
        } else if likelyBilingual || likelyWrongLanguage {
            confidence = 0.85
        } else {
            confidence = 0.75
        }

        var warnings: [String] = []
        if likelyBilingual {
            warnings.append("Detected substantial Simplified Chinese plus Latin/French-looking text.")
        }
        if likelyWrongLanguage {
            warnings.append("Detected very little Simplified Chinese text for this card.")
        }
        if sampleIsShort {
            warnings.append("Sample is short; review before merging.")
        }

        let detectedDescription: String
        if targetLanguage.code == LanguageOption.zhHans.code {
            if likelyBilingual {
                detectedDescription = "Simplified Chinese + French/Latin text"
            } else if likelyWrongLanguage {
                detectedDescription = "French/Latin text"
            } else {
                detectedDescription = "Simplified Chinese"
            }
        } else {
            detectedDescription = targetLanguage.displayName
        }

        return SubtitleLanguageProfile(
            previewLines: previewLines,
            detectedDescription: detectedDescription,
            targetCoverage: targetCoverage,
            latinLeakRatio: latinLeakRatio,
            mixedCueRatio: mixedCueRatio,
            confidence: confidence,
            isLikelyBilingual: likelyBilingual,
            isLikelyWrongLanguage: likelyWrongLanguage,
            warnings: warnings
        )
    }

    private static func frenchHintCount(in value: String) -> Int {
        let words = Set(value
            .lowercased()
            .replacingOccurrences(of: "[^a-zà-ÿ]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init))
        let hints: Set<String> = [
            "le", "la", "les", "des", "une", "un", "du", "de", "est", "que",
            "pas", "vous", "nous", "avec", "pour", "dans", "plus", "monsieur",
            "madame", "oui", "non", "être", "très"
        ]
        return words.intersection(hints).count
    }
}

private extension Unicode.Scalar {
    var isLatinLetter: Bool {
        (0x0041...0x005A ~= value) ||
            (0x0061...0x007A ~= value) ||
            (0x00C0...0x024F ~= value)
    }
}

struct AdaptiveProcessingOptions: Sendable {
    let hasEmbedded: Bool
    let hasSidecar: Bool

    var availableOptions: [SubtitleProcessingOption] {
        SubtitleProcessingOption.allCases.filter { option in
            switch option {
            case .useAvailable: return hasEmbedded || hasSidecar
            case .searchOnline, .translateWithLLM: return true
            }
        }
    }
}

struct OpenSubtitleSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let languageCode: String
    let languageName: String
    let fileFormat: String
    let downloads: Int
    let hd: Bool
    let subtitleID: String
    let fileSize: Int64?
    let fps: Double?
    let votes: Int?
    let rating: Double?
    let hearingImpaired: Bool
    let uploadDate: String?
    let featureTitle: String?
    let featureYear: Int?
    let featureType: String?
    let movieHashMatch: Bool
    let release: String?
    let fileName: String?
    let fromTrusted: Bool
    let foreignPartsOnly: Bool
    let aiTranslated: Bool
    let machineTranslated: Bool
    let comments: String?

    init(
        id: String,
        languageCode: String = "",
        languageName: String,
        fileFormat: String,
        downloads: Int,
        hd: Bool,
        subtitleID: String,
        fileSize: Int64?,
        fps: Double?,
        votes: Int?,
        rating: Double?,
        hearingImpaired: Bool,
        uploadDate: String?,
        featureTitle: String? = nil,
        featureYear: Int? = nil,
        featureType: String? = nil,
        movieHashMatch: Bool = false,
        release: String? = nil,
        fileName: String? = nil,
        fromTrusted: Bool = false,
        foreignPartsOnly: Bool = false,
        aiTranslated: Bool = false,
        machineTranslated: Bool = false,
        comments: String? = nil
    ) {
        self.id = id
        self.languageCode = languageCode
        self.languageName = languageName
        self.fileFormat = fileFormat
        self.downloads = downloads
        self.hd = hd
        self.subtitleID = subtitleID
        self.fileSize = fileSize
        self.fps = fps
        self.votes = votes
        self.rating = rating
        self.hearingImpaired = hearingImpaired
        self.uploadDate = uploadDate
        self.featureTitle = featureTitle
        self.featureYear = featureYear
        self.featureType = featureType
        self.movieHashMatch = movieHashMatch
        self.release = release
        self.fileName = fileName
        self.fromTrusted = fromTrusted
        self.foreignPartsOnly = foreignPartsOnly
        self.aiTranslated = aiTranslated
        self.machineTranslated = machineTranslated
        self.comments = comments
    }

    var qualitySignals: [CandidateQualitySignal] {
        var signals: [CandidateQualitySignal] = []
        if movieHashMatch { signals.append(.hashMatch) }
        if fromTrusted { signals.append(.trusted) }
        if hearingImpaired { signals.append(.hearingImpaired) }
        if foreignPartsOnly || metadataText.localizedCaseInsensitiveContains("forced") {
            signals.append(.forcedOnly)
        }
        if aiTranslated { signals.append(.aiTranslated) }
        if machineTranslated { signals.append(.machineTranslated) }
        if hasBilingualHint { signals.append(.bilingualHint) }
        if signals.contains(where: { $0.severity == .review || $0.severity == .warning }) {
            signals.append(.review)
        }
        return signals
    }

    var reviewSuggested: Bool {
        qualitySignals.contains { $0.kind == .review || $0.severity == .warning }
    }

    var featureSummary: String? {
        guard let featureTitle, !featureTitle.isEmpty else { return nil }
        if let featureYear {
            return "\(featureTitle) (\(featureYear))"
        }
        return featureTitle
    }

    var releaseSummary: String? {
        let value = release?.isEmpty == false ? release : fileName
        return value?.isEmpty == false ? value : nil
    }

    var downloadFailureContext: String {
        featureSummary ?? releaseSummary ?? languageName
    }

    private var metadataText: String {
        [
            languageCode,
            languageName,
            release,
            fileName,
            comments
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private var hasBilingualHint: Bool {
        let lowercased = metadataText.lowercased()
        if languageCode.lowercased() == "ze" {
            return true
        }
        let patterns = [
            "bilingual", "dual", "multi", "zh+fr", "zh-fr", "chinese+french",
            "chi+fre", "zho+fre", "zhcn+fr", "zh-cn+fr", "vostfr"
        ]
        return patterns.contains { lowercased.contains($0) }
    }
}

struct OpenSubtitleSearchResponse: Equatable, Sendable {
    let results: [OpenSubtitleSearchResult]
    let filteredCount: Int
    let queryTitle: String?
    let queryYear: Int?
}

enum PreviewMode: String, Codable, Sendable {
    case none
    case sourceOnly
    case bilingual
}

enum EmbeddedSubtitleExtractorKind: String, Codable, Sendable {
    case ffmpeg
    case mkvextract

    var displayName: String {
        switch self {
        case .ffmpeg:
            return "ffmpeg"
        case .mkvextract:
            return "mkvextract"
        }
    }

    var tool: MediaTool {
        switch self {
        case .ffmpeg:
            return .ffmpeg
        case .mkvextract:
            return .mkvextract
        }
    }
}

enum EmbeddedExportBackendKind: String, Codable, Sendable {
    case ffmpeg
    case mkvmerge

    var tool: MediaTool {
        switch self {
        case .ffmpeg:
            return .ffmpeg
        case .mkvmerge:
            return .mkvmerge
        }
    }
}

enum MediaTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case ffprobe
    case ffmpeg
    case mkvextract
    case mkvmerge

    var id: String { rawValue }

    var displayName: String { rawValue }
}

enum MediaToolOrigin: String, Codable, Sendable {
    case bundled
    case system
    case missing

    var displayName: String {
        switch self {
        case .bundled:
            return "Bundled"
        case .system:
            return "System"
        case .missing:
            return "Missing"
        }
    }
}

enum ContainerEmbeddingFamily: String, Codable, Sendable {
    case matroska
    case webm
    case unsupported
}

enum SubtitleCandidateAvailability: String, Codable, Sendable {
    case available
    case missing
    case needsFetch
    case needsTranslation
}

enum SubtitleCandidateLoadState: String, Codable, Sendable {
    case unloaded
    case loaded
    case failed
}

enum SubtitleCandidateLocator: Equatable, Sendable {
    case file(URL)
    case embedded(trackIndex: Int)
    case generated
}

struct LanguageOption: Codable, Hashable, Identifiable, Sendable {
    let code: String
    let displayName: String

    var id: String { code }

    var storageCode: String {
        switch code {
        case "zh-Hans": return "zh"
        default: return code
        }
    }

    var openSubtitlesCode: String {
        switch code {
        case "zh-Hans": return "zh-cn"
        case "pt": return "pt-pt"
        default: return code
        }
    }

    static let unknown = LanguageOption(code: "und", displayName: "Unknown")
    static let english = LanguageOption(code: "en", displayName: "English")
    static let french = LanguageOption(code: "fr", displayName: "French")
    static let german = LanguageOption(code: "de", displayName: "German")
    static let spanish = LanguageOption(code: "es", displayName: "Spanish")
    static let italian = LanguageOption(code: "it", displayName: "Italian")
    static let portuguese = LanguageOption(code: "pt", displayName: "Portuguese")
    static let polish = LanguageOption(code: "pl", displayName: "Polish")
    static let dutch = LanguageOption(code: "nl", displayName: "Dutch")
    static let swedish = LanguageOption(code: "sv", displayName: "Swedish")
    static let danish = LanguageOption(code: "da", displayName: "Danish")
    static let finnish = LanguageOption(code: "fi", displayName: "Finnish")
    static let czech = LanguageOption(code: "cs", displayName: "Czech")
    static let slovak = LanguageOption(code: "sk", displayName: "Slovak")
    static let hungarian = LanguageOption(code: "hu", displayName: "Hungarian")
    static let romanian = LanguageOption(code: "ro", displayName: "Romanian")
    static let bulgarian = LanguageOption(code: "bg", displayName: "Bulgarian")
    static let croatian = LanguageOption(code: "hr", displayName: "Croatian")
    static let slovenian = LanguageOption(code: "sl", displayName: "Slovenian")
    static let greek = LanguageOption(code: "el", displayName: "Greek")
    static let turkish = LanguageOption(code: "tr", displayName: "Turkish")
    static let zhHans = LanguageOption(code: "zh-Hans", displayName: "Simplified Chinese")

    static let supportedLanguages: [LanguageOption] = [
        .english, .french, .german, .spanish, .italian, .portuguese, .polish, .dutch,
        .swedish, .danish, .finnish, .czech, .slovak, .hungarian, .romanian, .bulgarian,
        .croatian, .slovenian, .greek, .turkish, .zhHans
    ]

    static let defaultSource: LanguageOption = .english
    static let defaultTarget: LanguageOption = .zhHans

    static func resolve(from rawValue: String?) -> LanguageOption? {
        guard let rawValue else { return nil }
        let key = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        let aliases: [String: LanguageOption] = [
            "en": .english, "eng": .english, "english": .english,
            "fr": .french, "fre": .french, "fra": .french, "french": .french,
            "de": .german, "ger": .german, "deu": .german, "german": .german,
            "es": .spanish, "spa": .spanish, "spanish": .spanish,
            "it": .italian, "ita": .italian, "italian": .italian,
            "pt": .portuguese, "por": .portuguese, "portuguese": .portuguese, "pt-br": .portuguese,
            "pl": .polish, "pol": .polish, "polish": .polish,
            "nl": .dutch, "dut": .dutch, "nld": .dutch, "dutch": .dutch,
            "sv": .swedish, "swe": .swedish, "swedish": .swedish,
            "da": .danish, "dan": .danish, "danish": .danish,
            "fi": .finnish, "fin": .finnish, "finnish": .finnish,
            "cs": .czech, "cze": .czech, "ces": .czech, "czech": .czech,
            "sk": .slovak, "slk": .slovak, "slo": .slovak, "slovak": .slovak,
            "hu": .hungarian, "hun": .hungarian, "hungarian": .hungarian,
            "ro": .romanian, "rum": .romanian, "ron": .romanian, "romanian": .romanian,
            "bg": .bulgarian, "bul": .bulgarian, "bulgarian": .bulgarian,
            "hr": .croatian, "hrv": .croatian, "croatian": .croatian,
            "sl": .slovenian, "slv": .slovenian, "slovenian": .slovenian,
            "el": .greek, "gre": .greek, "ell": .greek, "greek": .greek,
            "tr": .turkish, "tur": .turkish, "turkish": .turkish,
            "zh": .zhHans, "zh-cn": .zhHans, "zh-hans": .zhHans, "chi": .zhHans, "zho": .zhHans, "chs": .zhHans, "simplified chinese": .zhHans
        ]

        return aliases[key]
    }
}

struct SubtitleCue: Identifiable, Equatable, Sendable {
    let id: Int
    let startMilliseconds: Int
    let endMilliseconds: Int
    let rawText: String
    let plainText: String

    var durationMilliseconds: Int {
        max(0, endMilliseconds - startMilliseconds)
    }
}

struct SubtitleDocument: Equatable, Sendable {
    let language: LanguageOption
    let format: SubtitleFormatKind
    let origin: SubtitleOriginKind
    let sourceLabel: String
    let cues: [SubtitleCue]

    var cueCount: Int { cues.count }
}

struct ImportedSubtitleCandidate: Equatable, Sendable {
    let candidate: SubtitleCandidate
    let document: SubtitleDocument?
}

struct SubtitleCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let language: LanguageOption
    let format: SubtitleFormatKind
    let origin: SubtitleOriginKind
    let sourceLabel: String
    let availability: SubtitleCandidateAvailability
    let loadState: SubtitleCandidateLoadState
    let locator: SubtitleCandidateLocator
    let rankingScore: Double
    let fileURL: URL?
    let embeddedTrack: EmbeddedSubtitleTrack?
    let qualitySignals: [CandidateQualitySignal]
    let languageProfile: SubtitleLanguageProfile?
    let kind: CueKind?
    let relativePath: String?

    init(
        id: String,
        language: LanguageOption,
        format: SubtitleFormatKind,
        origin: SubtitleOriginKind,
        sourceLabel: String,
        availability: SubtitleCandidateAvailability,
        loadState: SubtitleCandidateLoadState,
        locator: SubtitleCandidateLocator,
        rankingScore: Double,
        fileURL: URL?,
        embeddedTrack: EmbeddedSubtitleTrack?,
        qualitySignals: [CandidateQualitySignal] = [],
        languageProfile: SubtitleLanguageProfile? = nil,
        kind: CueKind? = nil,
        relativePath: String? = nil
    ) {
        self.id = id
        self.language = language
        self.format = format
        self.origin = origin
        self.sourceLabel = sourceLabel
        self.availability = availability
        self.loadState = loadState
        self.locator = locator
        self.rankingScore = rankingScore
        self.fileURL = fileURL
        self.embeddedTrack = embeddedTrack
        self.qualitySignals = qualitySignals
        self.languageProfile = languageProfile
        self.kind = kind
        self.relativePath = relativePath
    }

    var displayTitle: String {
        var title = "\(sourceLabel) · \(origin.title)"
        if let kind {
            switch kind {
            case .sdh: title += " [SDH]"
            case .forcedNarrative: title += " [Forced]"
            case .ad: title += " [Ad]"
            case .dialogue, .unknown: break
            }
        }
        if let relativePath, relativePath.contains("/") {
            let folder = (relativePath as NSString).deletingLastPathComponent
            title += " · \(folder)/"
        }
        return title
    }

    var translationSourceLabel: String {
        "\(language.displayName) · \(sourceLabel) · \(origin.title)"
    }

    var isTextBased: Bool {
        embeddedTrack?.isTextBased ?? true
    }

    var reviewRequired: Bool {
        languageProfile?.reviewRequired == true ||
            qualitySignals.contains { $0.kind == .review || $0.severity == .warning }
    }

    func withQuality(
        signals: [CandidateQualitySignal],
        languageProfile: SubtitleLanguageProfile?
    ) -> SubtitleCandidate {
        SubtitleCandidate(
            id: id,
            language: language,
            format: format,
            origin: origin,
            sourceLabel: sourceLabel,
            availability: availability,
            loadState: loadState,
            locator: locator,
            rankingScore: languageProfile?.reviewRequired == true ? min(rankingScore, 0.45) : rankingScore,
            fileURL: fileURL,
            embeddedTrack: embeddedTrack,
            qualitySignals: signals,
            languageProfile: languageProfile
        )
    }
}

struct LanguageAvailability: Identifiable, Equatable, Sendable {
    let language: LanguageOption
    let textCandidateCount: Int
    let bitmapTrackCount: Int

    var id: String { language.id }

    var count: Int { textCandidateCount }

    var hasTextCandidates: Bool {
        textCandidateCount > 0
    }

    var hasBitmapOnlyCandidates: Bool {
        textCandidateCount == 0 && bitmapTrackCount > 0
    }

    var pickerLabel: String {
        if textCandidateCount > 0 && bitmapTrackCount > 0 {
            return "\(language.displayName) (\(textCandidateCount), +\(bitmapTrackCount) OCR)"
        }
        if textCandidateCount > 0 {
            return "\(language.displayName) (\(textCandidateCount))"
        }
        if bitmapTrackCount > 0 {
            return "\(language.displayName) (OCR only)"
        }
        return language.displayName
    }
}

struct SubtitleInventory: Equatable, Sendable {
    let videoURL: URL
    let containerName: String
    let candidates: [SubtitleCandidate]
    let bitmapTrackCounts: [LanguageOption: Int]
    let warnings: [String]

    func candidates(for language: LanguageOption) -> [SubtitleCandidate] {
        candidates
            .filter { $0.language == language && $0.availability == .available }
            .sorted { lhs, rhs in
                if lhs.rankingScore == rhs.rankingScore {
                    return lhs.displayTitle < rhs.displayTitle
                }
                return lhs.rankingScore > rhs.rankingScore
            }
    }

    func availability(for language: LanguageOption) -> LanguageAvailability {
        LanguageAvailability(
            language: language,
            textCandidateCount: candidates(for: language).count,
            bitmapTrackCount: bitmapTrackCounts[language, default: 0]
        )
    }

    var availableLanguages: [LanguageAvailability] {
        LanguageOption.supportedLanguages.map(availability(for:))
    }
}

struct BilingualCue: Identifiable, Equatable, Sendable {
    let id: Int
    let startMilliseconds: Int
    let endMilliseconds: Int
    let sourceText: String
    let targetText: String
    let alignmentConfidence: Double
    let alignmentStatus: CueAlignmentStatus

    var combinedText: String {
        [sourceText, targetText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct CueAlignmentMatch: Equatable, Sendable {
    let sourceCueID: Int
    let targetCueID: Int?
    let confidence: Double
    let status: CueAlignmentStatus
    let startDeltaMilliseconds: Int?
}

struct AlignmentReport: Equatable, Sendable {
    let matches: [CueAlignmentMatch]
    let matchedCueRatio: Double
    let lowConfidenceCueRatio: Double
    let unmatchedCueRatio: Double
    let medianStartDeltaMilliseconds: Double
    let monotonicityViolations: Int
    let averageConfidence: Double
    let detectedTimingOffsetMilliseconds: Int?
    let orphanedSourceCueIDs: Set<Int>
    let orphanedTargetCueIDs: Set<Int>

    static let empty = AlignmentReport(
        matches: [],
        matchedCueRatio: 0,
        lowConfidenceCueRatio: 0,
        unmatchedCueRatio: 1,
        medianStartDeltaMilliseconds: 0,
        monotonicityViolations: 0,
        averageConfidence: 0,
        detectedTimingOffsetMilliseconds: nil,
        orphanedSourceCueIDs: [],
        orphanedTargetCueIDs: []
    )
}

struct OffsetCorrection: Equatable, Sendable {
    let milliseconds: Int
    let appliedTo: Target

    enum Target: String, Equatable, Sendable {
        case source
        case target
    }
}

struct AlignmentIterationResult: Equatable, Sendable {
    let report: AlignmentReport
    let iterations: Int
    let detectedAds: Set<Int>  // cue IDs
    let appliedOffset: OffsetCorrection?
}

struct NormalizedReferenceSpan: Equatable, Sendable {
    let sourceCueID: Int
    let text: String
    let referenceCueIDs: [Int]
    let isMergedSpan: Bool
    let confidence: Double
    let primaryStatus: CueAlignmentStatus

    var isReliable: Bool {
        !text.isEmpty && confidence >= 0.30
    }

    var summaryLine: String {
        let spanKind = isMergedSpan ? "merged \(referenceCueIDs.count) cues" : "single cue"
        return "\(spanKind) · confidence \(String(format: "%.2f", confidence))"
    }
}

struct AlignmentNormalizationResult: Equatable, Sendable {
    let report: AlignmentReport
    let iterations: Int
    let detectedAds: Set<Int>
    let appliedOffset: OffsetCorrection?
    let primaryMatchedTextsBySourceCueID: [Int: String]
    let referenceSpansBySourceCueID: [Int: NormalizedReferenceSpan]

    var matchedCueCount: Int {
        report.matches.filter { $0.status == .matched }.count
    }

    var normalizedTextsBySourceCueID: [Int: String] {
        referenceSpansBySourceCueID.mapValues(\.text)
    }

    var isReliable: Bool {
        report.matchedCueRatio >= 0.45 || report.averageConfidence >= 0.55
    }

    var summaryLine: String {
        var parts = [
            "matched \(Int((report.matchedCueRatio * 100).rounded()))%",
            "low-confidence \(Int((report.lowConfidenceCueRatio * 100).rounded()))%"
        ]
        if !detectedAds.isEmpty {
            parts.append("ads removed \(detectedAds.count)")
        }
        if let appliedOffset {
            parts.append("offset \(appliedOffset.milliseconds)ms")
        }
        return parts.joined(separator: " · ")
    }
}

struct MergedSubtitleDocument: Equatable, Sendable {
    let sourceLanguage: LanguageOption
    let targetLanguage: LanguageOption
    let outputFormat: SubtitleFormatKind
    let cues: [BilingualCue]
    let alignmentReport: AlignmentReport
}

struct EmbeddedSubtitleTrack: Identifiable, Equatable, Sendable {
    let id: Int
    let index: Int
    let codecName: String
    let languageCode: String?
    let resolvedLanguage: LanguageOption?
    let title: String?
    let disposition: String?

    var displayLabel: String {
        let language = resolvedLanguage?.displayName ?? (languageCode ?? "Unknown")
        let parts = [language, title, codecName, disposition].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.joined(separator: " · ")
    }

    var isTextBased: Bool {
        let codec = codecName.lowercased()
        return [
            "subrip",
            "srt",
            "ass",
            "ssa",
            "webvtt",
            "mov_text",
            "text",
            "tx3g",
            "usf"
        ].contains(codec)
    }
}

struct AudioStream: Identifiable, Equatable, Sendable {
    let id: Int
    let index: Int
    let codecName: String
    let languageCode: String?
    let resolvedLanguage: LanguageOption?
    let channels: Int
    let bitrate: Int?

    var displayLabel: String {
        let language = resolvedLanguage?.displayName ?? (languageCode ?? "Unknown")
        let channelDesc = channels == 1 ? "mono" : (channels == 2 ? "stereo" : "\(channels)ch")
        return "\(language) · \(codecName) · \(channelDesc)"
    }
}

struct VideoInspectionReport: Equatable, Sendable {
    let videoURL: URL
    let containerName: String
    let embeddedSubtitleTracks: [EmbeddedSubtitleTrack]
    let audioStreams: [AudioStream]
    let localSubtitleSidecars: [URL]
    let warnings: [String]
}

struct ContainerEmbeddingProfile: Equatable, Sendable {
    let family: ContainerEmbeddingFamily
    let preferredOutputExtension: String
    let supportedSubtitleFormats: [SubtitleFormatKind]
    let preferredSubtitleFormat: SubtitleFormatKind
    let preferredSubtitleCodec: String
}

struct EmbeddedExportPlan: Equatable, Sendable {
    let family: ContainerEmbeddingFamily
    let outputExtension: String
    let subtitleFormat: SubtitleFormatKind
    let subtitleCodec: String
    let backend: EmbeddedExportBackendKind
    let compatibilityNote: String?

    var actionTitle: String {
        "Embed into \(outputExtension.uppercased())"
    }
}

struct EmbeddedExportCapability: Equatable, Sendable {
    let isAvailable: Bool
    let plan: EmbeddedExportPlan?
    let message: String
}

struct MediaToolStatus: Identifiable, Equatable, Sendable {
    let tool: MediaTool
    let origin: MediaToolOrigin
    let resolvedPath: String?
    let version: String?

    var id: String { tool.rawValue }

    var isAvailable: Bool {
        origin != .missing
    }

    var summaryLabel: String {
        switch origin {
        case .bundled:
            return "bundled \(tool.displayName)"
        case .system:
            return "system \(tool.displayName)"
        case .missing:
            return "\(tool.displayName) unavailable"
        }
    }

    var detailLabel: String {
        if let resolvedPath {
            return resolvedPath
        }
        return "Not available"
    }
}

struct SubtitleQualityReport: Equatable, Sendable {
    let decision: SubtitleDecision
    let score: Double
    let notes: [String]
    let metrics: [String: Double]
    let alignmentReport: AlignmentReport
}

enum WorkflowLogKind: String, Codable, Sendable {
    case info
    case error
}

struct WorkflowLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let message: String
    let kind: WorkflowLogKind
    let createdAt: Date

    init(id: UUID = UUID(), message: String, kind: WorkflowLogKind, createdAt: Date = .now) {
        self.id = id
        self.message = message
        self.kind = kind
        self.createdAt = createdAt
    }
}

struct ProviderSettings: Equatable, Sendable {
    // Legacy template retained only to migrate older saved settings into the new custom instructions field.
    static let defaultTranslationSystemPrompt = """
You are a professional subtitle translator specializing in video captions.

Your task: Translate subtitle cues from {sourceLanguage} to {targetLanguage}.

CRITICAL RULES:
- NEVER merge or split subtitle lines - keep each cue independent
- Use natural, conversational {targetLanguage} suitable for subtitles
- Add punctuation for rhythm and pacing when it improves readability
- Preserve names, places, brands, and recurring terms unless explicitly instructed otherwise
- Maintain consistent terminology throughout the translation
- Return translations as a JSON object: {"0":"...", "1":"..."}
- Return ONLY valid JSON with every requested index present
"""
    static let defaultTranslationCustomInstructions = ""
    static let providerPresetStoreKey = "translationProviderPresets"
    static let lastUsedProviderPresetIDKey = "selectedProviderPresetID"

    var lastUsedProviderPresetID: TranslationProviderPresetID = .ollama
    var providerPresetConfigurations: [TranslationProviderPresetConfiguration] = TranslationProviderPresetID.allCases.map {
        TranslationProviderPresetConfiguration.defaults(for: $0)
    }
    // Internal transport projection used by the translation services.
    var selectedProvider: TranslationProviderKind = .ollama
    var ollamaBaseURL: String = "http://localhost:11434"
    var ollamaModel: String = "qwen3:30b"
    var openAIBaseURL: String = "https://api.openai.com/v1"
    var openAIModel: String = "gpt-5-mini"
    var cloudAPIKeyAccount: String = "openai.apiKey"
    var useOpenAICompatibleEndpoint: Bool = false
    // Translation behavior settings
    var translationCustomInstructions: String = defaultTranslationCustomInstructions
    var translationContentType: ContentType = .drama
    var translationPassStrategy: TranslationPassStrategy = .qualityFirst
    var translationSinglePassPreference: SinglePassPreference = .auto
    var translationTemperature: Double = 0.2
    var referenceOverrideConfidenceThreshold: Double = 0.82
    var settingsSchemaVersion: Int = 2

    var availablePresets: [TranslationProviderPresetConfiguration] {
        TranslationProviderPresetID.allCases.map { configuration(for: $0) }
    }

    func configuration(for presetID: TranslationProviderPresetID) -> TranslationProviderPresetConfiguration {
        providerPresetConfigurations.first(where: { $0.id == presetID }) ?? .defaults(for: presetID)
    }

    mutating func updatePresetConfiguration(
        for presetID: TranslationProviderPresetID,
        _ update: (inout TranslationProviderPresetConfiguration) -> Void
    ) {
        let existingIndex = providerPresetConfigurations.firstIndex(where: { $0.id == presetID })
        if let existingIndex {
            update(&providerPresetConfigurations[existingIndex])
        } else {
            var configuration = TranslationProviderPresetConfiguration.defaults(for: presetID)
            update(&configuration)
            providerPresetConfigurations.append(configuration)
        }
    }

    func projected(for presetID: TranslationProviderPresetID) -> ProviderSettings {
        let configuration = configuration(for: presetID)
        var copy = self
        copy.lastUsedProviderPresetID = presetID
        copy.selectedProvider = configuration.transportKind
        switch configuration.transportKind {
        case .ollama:
            copy.ollamaBaseURL = configuration.baseURL
            copy.ollamaModel = configuration.model
            copy.useOpenAICompatibleEndpoint = configuration.useOpenAICompatibleEndpoint
        case .openAICompatible:
            copy.openAIBaseURL = configuration.baseURL
            copy.openAIModel = configuration.model
            copy.useOpenAICompatibleEndpoint = false
            copy.cloudAPIKeyAccount = configuration.descriptor.keychainAccount ?? "openai.apiKey"
        }
        return copy
    }

    func persist(to defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(providerPresetConfigurations) {
            defaults.set(data, forKey: Self.providerPresetStoreKey)
        }
        defaults.set(lastUsedProviderPresetID.rawValue, forKey: Self.lastUsedProviderPresetIDKey)
        defaults.set(translationCustomInstructions, forKey: "translationCustomInstructions")
        defaults.set(translationContentType.rawValue, forKey: "translationContentType")
        defaults.set(translationPassStrategy.rawValue, forKey: "translationPassStrategy")
        defaults.set(translationSinglePassPreference.rawValue, forKey: "translationSinglePassPreference")
        defaults.set(translationTemperature, forKey: "translationTemperature")
        defaults.set(referenceOverrideConfidenceThreshold, forKey: "referenceOverrideConfidenceThreshold")
        defaults.set(settingsSchemaVersion, forKey: "settingsSchemaVersion")
    }

    static func load(from defaults: UserDefaults = .standard) -> ProviderSettings {
        var settings = ProviderSettings()

        if let storedPresetID = defaults.string(forKey: Self.lastUsedProviderPresetIDKey),
           let presetID = TranslationProviderPresetID(rawValue: storedPresetID) {
            settings.lastUsedProviderPresetID = presetID
        } else {
            settings.lastUsedProviderPresetID = migrateLastUsedPresetID(from: defaults)
        }

        if let data = defaults.data(forKey: Self.providerPresetStoreKey),
           let decoded = try? JSONDecoder().decode([TranslationProviderPresetConfiguration].self, from: data) {
            settings.providerPresetConfigurations = TranslationProviderPresetID.allCases.map { presetID in
                decoded.first(where: { $0.id == presetID }) ?? .defaults(for: presetID)
            }
        } else {
            settings.providerPresetConfigurations = migratePresetConfigurations(from: defaults)
        }

        // One-shot migration: remove obsolete keys from pre-schema-v2 installs
        let storedVersion = defaults.integer(forKey: "settingsSchemaVersion")
        if storedVersion < 2 {
            for key in ["translationQualityProfile", "translationStrictness",
                        "translationKeepNames", "translationKeepLocations",
                        "translationKeepBrands", "translationBatchSize"] {
                defaults.removeObject(forKey: key)
            }
            defaults.set(2, forKey: "settingsSchemaVersion")
        }

        settings.translationCustomInstructions = loadTranslationCustomInstructions(from: defaults)
        settings.translationContentType =
            ContentType(rawValue: defaults.string(forKey: "translationContentType") ?? ContentType.drama.rawValue)
            ?? .drama
        settings.translationPassStrategy =
            TranslationPassStrategy(rawValue: defaults.string(forKey: "translationPassStrategy") ?? TranslationPassStrategy.qualityFirst.rawValue)
            ?? .qualityFirst
        settings.translationSinglePassPreference =
            SinglePassPreference(rawValue: defaults.string(forKey: "translationSinglePassPreference") ?? SinglePassPreference.auto.rawValue)
            ?? .auto
        settings.translationTemperature = defaults.object(forKey: "translationTemperature") as? Double ?? 0.2
        let defaultThreshold = ProviderSettings().referenceOverrideConfidenceThreshold
        let threshold = defaults.object(forKey: "referenceOverrideConfidenceThreshold") as? Double ?? defaultThreshold
        settings.referenceOverrideConfidenceThreshold = min(max(threshold, 0), 1)

        return settings
    }

    private static func loadTranslationCustomInstructions(from defaults: UserDefaults) -> String {
        if let currentValue = normalizedInstruction(defaults.string(forKey: "translationCustomInstructions")) {
            return currentValue
        }

        let legacySystemPrompt = normalizedInstruction(defaults.string(forKey: "translationSystemPrompt"))
        let defaultSystemPrompt = normalizedInstruction(defaultTranslationSystemPrompt)
        let migratedSystemPrompt = legacySystemPrompt == defaultSystemPrompt ? nil : legacySystemPrompt
        let legacyAdvancedOverride = normalizedInstruction(defaults.string(forKey: "translationAdvancedPromptOverride"))

        return [migratedSystemPrompt, legacyAdvancedOverride]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    private static func normalizedInstruction(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func migrateLastUsedPresetID(from defaults: UserDefaults) -> TranslationProviderPresetID {
        let legacySelectedProvider = TranslationProviderKind(
            rawValue: defaults.string(forKey: "selectedProvider") ?? TranslationProviderKind.ollama.rawValue
        ) ?? .ollama
        switch legacySelectedProvider {
        case .ollama:
            return .ollama
        case .openAICompatible:
            let legacyBaseURL = defaults.string(forKey: "openAIBaseURL") ?? TranslationProviderPresetID.openAI.descriptor.defaultBaseURL
            return matchedCloudPresetID(for: legacyBaseURL)
        }
    }

    private static func migratePresetConfigurations(from defaults: UserDefaults) -> [TranslationProviderPresetConfiguration] {
        var configurations = TranslationProviderPresetID.allCases.map { TranslationProviderPresetConfiguration.defaults(for: $0) }

        let legacyOllamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? TranslationProviderPresetID.ollama.descriptor.defaultBaseURL
        let legacyOllamaModel = defaults.string(forKey: "ollamaModel") ?? TranslationProviderPresetID.ollama.descriptor.defaultModel
        let legacyOllamaUsesChatCompletions = defaults.bool(forKey: "useOpenAICompatibleEndpoint")
        if let index = configurations.firstIndex(where: { $0.id == .ollama }) {
            configurations[index].baseURL = legacyOllamaBaseURL
            configurations[index].model = legacyOllamaModel
            configurations[index].useOpenAICompatibleEndpoint = legacyOllamaUsesChatCompletions
        }

        let legacyCloudBaseURL = defaults.string(forKey: "openAIBaseURL") ?? TranslationProviderPresetID.openAI.descriptor.defaultBaseURL
        let legacyCloudModel = defaults.string(forKey: "openAIModel") ?? TranslationProviderPresetID.openAI.descriptor.defaultModel
        let migratedCloudPresetID = matchedCloudPresetID(for: legacyCloudBaseURL)
        if let migratedIndex = configurations.firstIndex(where: { $0.id == migratedCloudPresetID }) {
            configurations[migratedIndex].baseURL = legacyCloudBaseURL
            configurations[migratedIndex].model = legacyCloudModel
        }
        if migratedCloudPresetID != .customOpenAICompatible,
           let customIndex = configurations.firstIndex(where: { $0.id == .customOpenAICompatible }) {
            configurations[customIndex].baseURL = legacyCloudBaseURL
            configurations[customIndex].model = legacyCloudModel
        }

        return configurations
    }

    private static func matchedCloudPresetID(for baseURL: String) -> TranslationProviderPresetID {
        let normalizedBaseURL = normalizeBaseURL(baseURL)
        let host = URL(string: normalizedBaseURL)?.host?.lowercased() ?? normalizedBaseURL.lowercased()

        if host.contains("api.openai.com") { return .openAI }
        if host.contains("api.deepseek.com") { return .deepSeek }
        if host.contains("openrouter.ai") { return .openRouter }
        if host.contains("siliconflow.cn") { return .siliconFlow }
        if host.contains("api.groq.com") { return .groq }
        if host.contains("together.xyz") { return .togetherAI }
        if host.contains("fireworks.ai") { return .fireworksAI }
        if host.contains("api.x.ai") { return .xAI }

        if let exactMatch = TranslationProviderPresetID.allCases.first(where: {
            $0 != .ollama && normalizeBaseURL($0.descriptor.defaultBaseURL) == normalizedBaseURL
        }) {
            return exactMatch
        }
        return .customOpenAICompatible
    }

    private static func normalizeBaseURL(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            .lowercased()
    }
}

struct OpenSubtitlesSettings: Equatable, Sendable {
    var username: String = ""
    var useDownloadedCandidateByDefault: Bool = true
}

enum WorkflowError: LocalizedError, Equatable {
    case missingSourceSubtitle
    case missingTargetSubtitle
    case missingExportDestination
    case dependencyUnavailable(String)
    case unsupported(String)
    case credentialsMissing(String)
    case networkError(String)
    case processTimedOut(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .missingSourceSubtitle:
            return "Select a source language with an available subtitle candidate."
        case .missingTargetSubtitle:
            return "Select a target language with an available subtitle candidate."
        case .missingExportDestination:
            return "Choose an export destination first."
        case .dependencyUnavailable(let message),
             .unsupported(let message),
             .credentialsMissing(let message),
             .networkError(let message),
             .processTimedOut(let message),
             .runtime(let message):
            return message
        }
    }
}

extension Array where Element == SubtitleCue {
    var nonEmptyCueRatio: Double {
        guard !isEmpty else { return 0 }
        let nonEmpty = filter { !$0.plainText.normalizedSubtitleText.isEmpty }
        return Double(nonEmpty.count) / Double(count)
    }
}

extension MergedSubtitleDocument {
    func defaultSidecarURL(for videoURL: URL) -> URL {
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let fileName = "\(stem).\(sourceLanguage.storageCode)-\(targetLanguage.storageCode).\(outputFormat.fileExtension)"
        return videoURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    func defaultEmbeddedOutputURL(for videoURL: URL, outputExtension: String? = nil) -> URL {
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let ext = outputExtension ?? videoURL.pathExtension.lowercased()
        let normalizedExtension = ext.isEmpty ? "mkv" : ext
        let fileName = "\(stem).\(sourceLanguage.storageCode)-\(targetLanguage.storageCode).\(normalizedExtension)"
        return videoURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }
}

extension AlignmentReport {
    var summaryLine: String {
        let matched = Int((matchedCueRatio * 100).rounded())
        let lowConfidence = matches.filter { $0.status == .lowConfidence }.count
        let unmatched = matches.filter { $0.status == .unmatched }.count
        return "Matched \(matched)% · low-confidence \(lowConfidence) · blank \(unmatched)"
    }
}

extension SubtitleFormatKind {
    var displayName: String {
        switch self {
        case .srt:
            return "SRT"
        case .ass:
            return "ASS"
        case .vtt:
            return "WebVTT"
        case .unknown:
            return "Unknown"
        }
    }
}

extension ContainerEmbeddingProfile {
    static func resolve(from report: VideoInspectionReport) -> ContainerEmbeddingProfile {
        let containerName = report.containerName.lowercased()
        let pathExtension = report.videoURL.pathExtension.lowercased()

        if pathExtension == "webm" || containerName == "webm" {
            return ContainerEmbeddingProfile(
                family: .webm,
                preferredOutputExtension: "webm",
                supportedSubtitleFormats: [.vtt],
                preferredSubtitleFormat: .vtt,
                preferredSubtitleCodec: "webvtt"
            )
        }

        if pathExtension == "mkv" || containerName.contains("matroska") {
            return ContainerEmbeddingProfile(
                family: .matroska,
                preferredOutputExtension: pathExtension.isEmpty ? "mkv" : pathExtension,
                supportedSubtitleFormats: [.srt, .ass, .vtt],
                preferredSubtitleFormat: .srt,
                preferredSubtitleCodec: "srt"
            )
        }

        return ContainerEmbeddingProfile(
            family: .unsupported,
            preferredOutputExtension: pathExtension,
            supportedSubtitleFormats: [],
            preferredSubtitleFormat: .unknown,
            preferredSubtitleCodec: "copy"
        )
    }

    func plan(
        for merged: MergedSubtitleDocument,
        backend: EmbeddedExportBackendKind
    ) -> EmbeddedExportPlan? {
        guard family != .unsupported else { return nil }

        let subtitleFormat = supportedSubtitleFormats.contains(merged.outputFormat)
            ? merged.outputFormat
            : preferredSubtitleFormat

        let subtitleCodec: String
        switch subtitleFormat {
        case .srt:
            subtitleCodec = "srt"
        case .ass:
            subtitleCodec = "ass"
        case .vtt:
            subtitleCodec = "webvtt"
        case .unknown:
            return nil
        }

        let note: String?
        if subtitleFormat != merged.outputFormat {
            note = "Embedding will use \(subtitleFormat.displayName) for \(preferredOutputExtension.uppercased()) compatibility."
        } else {
            note = nil
        }

        return EmbeddedExportPlan(
            family: family,
            outputExtension: preferredOutputExtension,
            subtitleFormat: subtitleFormat,
            subtitleCodec: subtitleCodec,
            backend: backend,
            compatibilityNote: note
        )
    }
}

extension String {
    var normalizedSubtitleText: String {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var looksLikeSimplifiedChinese: Bool {
        let simplifiedOnly = Set("汉气门广东乐书云后体价们会众优传伤伦伟侧俩关兴养兽写军农冲决况冻净刚刘则创别剂剑办务动协单卖卢卫压厉厅历厉厂双发变叶号叹只台后听启员国图团围园圆圣场坏块坚坛坝坟坠垄垒垦埋够头夹夺奋奖妆妇妈孙学宝实审宪宫宽宾寝对导尔尘尝层届岁岂岗岛岭岳峡币帅师帐帘带帮庄庆庐庙应库废开张弥弯录归当彻径忆忧怀态怜总恋恒惊惧惨惯户扑执扩扫扬扰抚抛抠护报担拟拢拥择挂挤挥损捡换据掷掸掺揽搀摄摆摇摊撑撵擒敌数断无旧时显晋晒晓暂术机杀杂权条来杨极构枪标栈栋栏树样桥检楼欢欧欲残毁毕毙汇汉汤沟没沥沦沪泪泽洁洒浓测济浑涛润涂涩淀渊渔湾湿满滤滥灭灯灵灾炀炉炖点炼烁烂烟烦烧烫热爱爷牵犹独狭狮猎玛现球琐电画畅疗疮疯监盖盘盗盐眯着瞒矶矿码砖砚砰础硕确礼祷祸禀离种积称稳穷窃竞笔笋筹签简粮紧纠纤约级纪纫纬纯纳纵纷纸纹纺线练组绅细织终绊绍经绑结绕绘给络绝统继绩绪续维绵综绿缀缝编缩缴罐网罗罚置羡习翘耻联聪肃肠肤肾肿胀胜胶脑脚脱脸舆舰舱艺节芦苹范茧荆荐荡药营萧萨蓝虑虽虏虫蚀蚁蚂虽观规视览觉觅觇触订计认讥讨让训议讯记讲许论讼设访证评识诈诉诊诃诅词译试诗诚话诞诡询该详诧诫诬语误诱诲说诵请诸诺读课谁调谅谈谊谋谜谢谣谤谨谦谧谭谱贝贞负贡财责贤败账货质贩贪贫购贯贴贵贷贸费贺贻资赏赐赔赖赚赛赞赶赵趋跃车轨轩转轮软轰轿较辅辆辞边辽达迁过迈运还这进远违连迟适选逊递逻遗邮邻郑郁郏酝酱释里鉴铜锈锋锌锐错锡键镇镜长门闩闭问闯闷闻阀阁阅队阶际陆陈阴阳际险随隐难雾静鞭韦页顶项顺须顾顿颁颂预颅领颇颈频题颜额飞饭饮饰饱饲饶饼馆驱驳驶驷驻驼驾骂骄验骏骗骚骤鲍鸡鸣麦黄黉龄龙龟").contains
        return contains(where: simplifiedOnly)
    }
}
