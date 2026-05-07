import Foundation

actor TranslationOrchestrator {
    private let translationService: any TranslationServicing
    private let settings: ProviderSettings
    private let aligner = SubtitleAligner()

    struct Config: Sendable {
        let batchSize: Int
        let maxRetries: Int
        let maxPromptCharacters: Int
        let customInstructions: String
        let episodeContext: String
        let keepNames: Bool
        let keepLocations: Bool
        let keepBrands: Bool
        let maxLinesPerCue: Int
        let targetCharactersPerLine: Int
        let qualityProfile: TranslationQualityProfile
        let passStrategy: TranslationPassStrategy
        let strictness: TranslationStrictness
        let referenceSelection: ReferenceSubtitleSelection?
        let referenceDocument: SubtitleDocument?
        let referenceOverrideConfidenceThreshold: Double

        static let `default` = Config(
            batchSize: 50,
            maxRetries: 2,
            maxPromptCharacters: 6_500,
            customInstructions: ProviderSettings.defaultTranslationCustomInstructions,
            episodeContext: "",
            keepNames: true,
            keepLocations: true,
            keepBrands: false,
            maxLinesPerCue: 2,
            targetCharactersPerLine: 42,
            qualityProfile: .general,
            passStrategy: .qualityFirst,
            strictness: .balanced,
            referenceSelection: nil,
            referenceDocument: nil,
            referenceOverrideConfidenceThreshold: ProviderSettings().referenceOverrideConfidenceThreshold
        )
    }

    struct Progress: Sendable {
        let completed: Int
        let total: Int
        let partialResults: [String]
        let activeBatchRange: TranslationBatchRange
        let lastCompletedBatchRange: TranslationBatchRange
        let brief: TranslationBrief
        let reviewReport: TranslationReviewReport?
        let statusMessage: String
    }

    enum OutcomeState: Sendable {
        case completed
        case paused
        case stopped
        case cancelled
    }

    struct Outcome: Sendable {
        let state: OutcomeState
        let results: [String]
        let completed: Int
        let total: Int
        let lastCompletedBatchRange: TranslationBatchRange?
        let brief: TranslationBrief
        let reviewReport: TranslationReviewReport?
    }

    private struct BatchTranslationOutcome: Sendable {
        let batchRange: TranslationBatchRange
        let translated: [String]
        let reviewReport: TranslationReviewReport?
    }

    init(translationService: any TranslationServicing, settings: ProviderSettings) {
        self.translationService = translationService
        self.settings = settings
    }

    func translate(
        cues: [SubtitleCue],
        from sourceLanguage: LanguageOption,
        to targetLanguage: LanguageOption,
        initialResults: [String] = [],
        startIndex: Int = 0,
        config: Config = .default,
        controlHandler: @Sendable @escaping () async -> TranslationPendingControl?,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> Outcome {
        let totalCount = cues.count
        let brief = buildTranslationBrief(cues: cues, episodeContext: config.episodeContext)
        let promptPolicy = buildPromptPolicy(config: config, to: targetLanguage)
        let referenceCueSpans = buildReferenceCueSpans(
            sourceCues: cues,
            sourceLanguage: sourceLanguage,
            referenceDocument: config.referenceDocument
        )
        let usesReviewPass = config.passStrategy != .draftOnly

        var results = normalizeInitialResults(initialResults, totalCount: totalCount)
        var batchStart = min(max(startIndex, 0), totalCount)
        var lastCompletedBatchRange: TranslationBatchRange?
        var aggregatedFindings: [TranslationCueFinding] = []

        while batchStart < totalCount {
            let plannedBatchSize = plannedBatchSize(
                from: batchStart,
                cues: cues,
                results: results,
                config: config,
                brief: brief,
                from: sourceLanguage,
                to: targetLanguage,
                promptPolicy: promptPolicy,
                referenceCueSpans: referenceCueSpans
            )

            let plannedRange = TranslationBatchRange(
                startIndex: batchStart,
                endIndex: min(batchStart + plannedBatchSize, totalCount) - 1
            )

            let batchOutcome = try await translateBatch(
                cues: cues,
                results: results,
                batchRange: plannedRange,
                from: sourceLanguage,
                to: targetLanguage,
                brief: brief,
                promptPolicy: promptPolicy,
                referenceCueSpans: referenceCueSpans,
                config: config
            )

            let completedRange = batchOutcome.batchRange
            let completedCount = completedRange.endIndex + 1

            for (offset, text) in batchOutcome.translated.enumerated() {
                results[completedRange.startIndex + offset] = text
            }

            lastCompletedBatchRange = completedRange
            if let report = batchOutcome.reviewReport {
                aggregatedFindings.append(contentsOf: report.findings)
            }

            let aggregateReviewReport = usesReviewPass
                ? combinedReviewReport(from: aggregatedFindings)
                : nil

            progressHandler(
                Progress(
                    completed: completedCount,
                    total: totalCount,
                    partialResults: results,
                    activeBatchRange: completedRange,
                    lastCompletedBatchRange: completedRange,
                    brief: brief,
                    reviewReport: aggregateReviewReport,
                    statusMessage: "Quality-checked cues \(completedRange.startIndex + 1)-\(completedRange.endIndex + 1) of \(totalCount)"
                )
            )

            switch await controlHandler() {
            case .pause:
                return Outcome(
                    state: .paused,
                    results: results,
                    completed: completedCount,
                    total: totalCount,
                    lastCompletedBatchRange: completedRange,
                    brief: brief,
                    reviewReport: aggregateReviewReport
                )
            case .stop:
                return Outcome(
                    state: .stopped,
                    results: results,
                    completed: completedCount,
                    total: totalCount,
                    lastCompletedBatchRange: completedRange,
                    brief: brief,
                    reviewReport: aggregateReviewReport
                )
            case .cancel:
                return Outcome(
                    state: .cancelled,
                    results: results,
                    completed: completedCount,
                    total: totalCount,
                    lastCompletedBatchRange: completedRange,
                    brief: brief,
                    reviewReport: aggregateReviewReport
                )
            case nil:
                break
            }

            batchStart = completedCount
        }

        return Outcome(
            state: .completed,
            results: results,
            completed: totalCount,
            total: totalCount,
            lastCompletedBatchRange: lastCompletedBatchRange,
            brief: brief,
            reviewReport: usesReviewPass ? combinedReviewReport(from: aggregatedFindings) : nil
        )
    }

    private func translateBatch(
        cues: [SubtitleCue],
        results: [String],
        batchRange: TranslationBatchRange,
        from sourceLanguage: LanguageOption,
        to targetLanguage: LanguageOption,
        brief: TranslationBrief,
        promptPolicy: TranslationPromptPolicy,
        referenceCueSpans: [Int: NormalizedReferenceSpan],
        config: Config
    ) async throws -> BatchTranslationOutcome {
        var currentBatchRange = batchRange
        var retryCount = 0
        var prefersShorterSubtitles = false

        while true {
            do {
                let batchTexts = sourceTexts(in: cues, range: currentBatchRange)
                let draftRequest = buildTranslationRequest(
                    passKind: .draft,
                    cues: cues,
                    results: results,
                    batchRange: currentBatchRange,
                    from: sourceLanguage,
                    to: targetLanguage,
                    brief: brief,
                    promptPolicy: promptPolicy,
                    referenceCueSpans: referenceCueSpans,
                    config: config,
                    prefersShorterSubtitles: prefersShorterSubtitles,
                    currentDraft: [],
                    reviewReport: nil
                )
                let draftResponse = try await translationService.translate(draftRequest, settings: settings)
                let draftTranslations = try parseTranslationResponse(draftResponse.content, expectedCount: batchTexts.count)

                try validateTranslationBatch(
                    sourceTexts: batchTexts,
                    translatedTexts: draftTranslations,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    config: config
                )

                var reviewReport: TranslationReviewReport?
                var finalTranslations = draftTranslations

                if config.passStrategy != .draftOnly {
                    let critiqueRequest = buildTranslationRequest(
                        passKind: .critique,
                        cues: cues,
                        results: results,
                        batchRange: currentBatchRange,
                        from: sourceLanguage,
                        to: targetLanguage,
                        brief: brief,
                        promptPolicy: promptPolicy,
                        referenceCueSpans: referenceCueSpans,
                        config: config,
                        prefersShorterSubtitles: prefersShorterSubtitles,
                        currentDraft: draftTranslations,
                        reviewReport: nil
                    )
                    let critiqueResponse = try await translationService.translate(critiqueRequest, settings: settings)
                    reviewReport = try parseReviewReport(
                        critiqueResponse.content,
                        cues: cues,
                        batchRange: currentBatchRange,
                        expectedCount: batchTexts.count,
                        referenceCueSpans: referenceCueSpans,
                        confidenceThreshold: config.referenceOverrideConfidenceThreshold
                    )

                    let shouldRewrite: Bool
                    switch config.passStrategy {
                    case .draftOnly:
                        shouldRewrite = false
                    case .reviewAndRewrite:
                        shouldRewrite = reviewReport?.findings.isEmpty == false
                    case .qualityFirst:
                        shouldRewrite = true
                    }

                    if shouldRewrite {
                        let rewriteRequest = buildTranslationRequest(
                            passKind: .rewrite,
                            cues: cues,
                            results: results,
                            batchRange: currentBatchRange,
                            from: sourceLanguage,
                            to: targetLanguage,
                            brief: brief,
                            promptPolicy: promptPolicy,
                            referenceCueSpans: referenceCueSpans,
                            config: config,
                            prefersShorterSubtitles: prefersShorterSubtitles,
                            currentDraft: draftTranslations,
                            reviewReport: reviewReport
                        )
                        let rewriteResponse = try await translationService.translate(rewriteRequest, settings: settings)
                        finalTranslations = try parseTranslationResponse(rewriteResponse.content, expectedCount: batchTexts.count)
                    }

                    try validateTranslationBatch(
                        sourceTexts: batchTexts,
                        translatedTexts: finalTranslations,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        config: config
                    )
                }

                return BatchTranslationOutcome(
                    batchRange: currentBatchRange,
                    translated: finalTranslations,
                    reviewReport: reviewReport
                )
            } catch {
                if !prefersShorterSubtitles {
                    prefersShorterSubtitles = true
                    continue
                }

                if currentBatchRange.completedCount > 1 {
                    let reducedCount = max(1, currentBatchRange.completedCount / 2)
                    currentBatchRange = TranslationBatchRange(
                        startIndex: currentBatchRange.startIndex,
                        endIndex: currentBatchRange.startIndex + reducedCount - 1
                    )
                    continue
                }

                retryCount += 1
                if retryCount > config.maxRetries {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(retryCount)) * 250_000_000))
            }
        }
    }

    private func buildTranslationRequest(
        passKind: TranslationPassKind,
        cues: [SubtitleCue],
        results: [String],
        batchRange: TranslationBatchRange,
        from sourceLanguage: LanguageOption,
        to targetLanguage: LanguageOption,
        brief: TranslationBrief,
        promptPolicy: TranslationPromptPolicy,
        referenceCueSpans: [Int: NormalizedReferenceSpan],
        config: Config,
        prefersShorterSubtitles: Bool,
        currentDraft: [String],
        reviewReport: TranslationReviewReport?
    ) -> TranslationRequest {
        let systemPrompt = buildSystemPrompt(
            passKind: passKind,
            from: sourceLanguage,
            to: targetLanguage,
            promptPolicy: promptPolicy,
            brief: brief,
            config: config,
            prefersShorterSubtitles: prefersShorterSubtitles
        )

        let userPrompt = buildUserPrompt(
            passKind: passKind,
            cues: cues,
            results: results,
            batchRange: batchRange,
            brief: brief,
            referenceCueSpans: referenceCueSpans,
            config: config,
            prefersShorterSubtitles: prefersShorterSubtitles,
            currentDraft: currentDraft,
            reviewReport: reviewReport
        )

        let responseFormat: TranslationResponseFormat
        switch passKind {
        case .draft, .rewrite:
            responseFormat = translationService.capabilities.supportsStructuredOutput
                ? .jsonObject(schemaName: "subtitle_translations")
                : .plainText
        case .critique:
            responseFormat = .plainText
        }

        return TranslationRequest(
            passKind: passKind,
            messages: [
                TranslationMessage(role: .system, content: systemPrompt),
                TranslationMessage(role: .user, content: userPrompt)
            ],
            responseFormat: responseFormat
        )
    }

    private func buildSystemPrompt(
        passKind: TranslationPassKind,
        from sourceLanguage: LanguageOption,
        to targetLanguage: LanguageOption,
        promptPolicy: TranslationPromptPolicy,
        brief: TranslationBrief,
        config: Config,
        prefersShorterSubtitles: Bool
    ) -> String {
        var lines: [String] = [promptPolicy.baseRole]

        switch passKind {
        case .draft:
            lines.append("Your task: draft subtitle translations from \(sourceLanguage.displayName) to \(targetLanguage.displayName).")
        case .critique:
            lines.append("Your task: review subtitle translations from \(sourceLanguage.displayName) to \(targetLanguage.displayName).")
        case .rewrite:
            lines.append("Your task: revise subtitle translations from \(sourceLanguage.displayName) to \(targetLanguage.displayName).")
        }

        lines.append("")
        lines.append("HARD RULES:")
        lines.append(contentsOf: promptPolicy.hardRules.map { "- \($0)" })
        lines.append("- Keep cue boundaries intact and never merge or split cues.")
        lines.append("- Keep subtitle phrasing concise and readable on screen.")
        lines.append("- Prefer no more than \(config.maxLinesPerCue) lines per cue when possible.")
        lines.append("- Keep line lengths comfortable for subtitle reading.")

        let preservationRules = [
            config.keepNames ? "names" : nil,
            config.keepLocations ? "locations" : nil,
            config.keepBrands ? "brands" : nil
        ]
        .compactMap { $0 }

        if !preservationRules.isEmpty {
            lines.append("- Preserve these exactly when they appear unless critique explicitly approves a change: \(preservationRules.joined(separator: ", ")).")
        }

        if !promptPolicy.profileNotes.isEmpty {
            lines.append("")
            lines.append("STYLE PROFILE:")
            lines.append(contentsOf: promptPolicy.profileNotes.map { "- \($0)" })
        }

        if !promptPolicy.strictnessNotes.isEmpty {
            lines.append("")
            lines.append("PRIORITY BIAS:")
            lines.append(contentsOf: promptPolicy.strictnessNotes.map { "- \($0)" })
        }

        if !brief.registerSummary.isEmpty {
            lines.append("")
            lines.append("REGISTER SUMMARY:")
            lines.append("- \(brief.registerSummary)")
        }

        if prefersShorterSubtitles {
            lines.append("- Retry mode: shorten wording, trim filler, and prioritize subtitle fit without changing meaning.")
        }

        if !promptPolicy.advancedInstructions.isEmpty {
            lines.append("")
            lines.append("ADDITIONAL OVERRIDES:")
            lines.append(promptPolicy.advancedInstructions)
        }

        switch passKind {
        case .draft, .rewrite:
            if !translationService.capabilities.supportsStructuredOutput {
                lines.append("")
                lines.append("STRICT OUTPUT CONTRACT:")
                lines.append("- Return exactly one JSON object.")
                lines.append("- Use string keys for every requested index starting at 0.")
                lines.append("- Every value must be the translated text for that index.")
                lines.append("- Do not include markdown, commentary, code fences, or extra keys.")
            }
        case .critique:
            lines.append("")
            lines.append("STRICT OUTPUT CONTRACT:")
            lines.append("- Return exactly one JSON object with fields 'summary' and 'findings'.")
            lines.append("- Each finding must include: index, severity, kind, message, suggestedTranslation, referenceDecision, confidence.")
            lines.append("- Use 'overrideWithReference' only when the reference cue is clearly better and confidence is high.")
            lines.append("- If the source and reference disagree but confidence is not high, keep referenceDecision as 'supportReference' or 'keepSource'.")
        }

        return lines.joined(separator: "\n")
    }

    private func buildUserPrompt(
        passKind: TranslationPassKind,
        cues: [SubtitleCue],
        results: [String],
        batchRange: TranslationBatchRange,
        brief: TranslationBrief,
        referenceCueSpans: [Int: NormalizedReferenceSpan],
        config: Config,
        prefersShorterSubtitles: Bool,
        currentDraft: [String],
        reviewReport: TranslationReviewReport?
    ) -> String {
        let previousTranslated = neighboringTranslatedTexts(results: results, before: batchRange.startIndex)
        let previousSource = neighboringSourceTexts(cues: cues, before: batchRange.startIndex)
        let upcomingSource = neighboringSourceTexts(cues: cues, after: batchRange.endIndex)
        let batchTexts = sourceTexts(in: cues, range: batchRange)
        let referenceSpans = referenceSpans(in: cues, range: batchRange, referenceCueSpans: referenceCueSpans)

        var lines: [String] = []
        lines.append("TASK: \(passKind.rawValue.uppercased())")

        if !brief.episodeContext.isEmpty {
            lines.append("")
            lines.append("SCENE CONTEXT:")
            lines.append(brief.episodeContext)
        }

        if !brief.recurringTerms.isEmpty {
            lines.append("")
            lines.append("RECURRING TERMS:")
            lines.append(brief.recurringTerms.joined(separator: ", "))
        }

        if !previousTranslated.isEmpty {
            lines.append("")
            lines.append("PREVIOUS TRANSLATED CUES:")
            for (index, text) in previousTranslated.enumerated() {
                lines.append("\(index): \(text)")
            }
        }

        if !previousSource.isEmpty {
            lines.append("")
            lines.append("PREVIOUS SOURCE CUES:")
            for (index, text) in previousSource.enumerated() {
                lines.append("\(index): \(text)")
            }
        }

        lines.append("")
        lines.append("SOURCE CUES:")
        for (index, text) in batchTexts.enumerated() {
            lines.append("\(index): \(text)")
        }

        if !referenceSpans.isEmpty {
            lines.append("")
            lines.append("OPTIONAL TRUSTED REFERENCE SUBTITLE:")
            for (index, span) in referenceSpans.sorted(by: { $0.key < $1.key }) {
                lines.append("\(index): [\(span.summaryLine)] \(span.text)")
            }
            lines.append("Use the reference only as supporting evidence unless confidence is high.")
        }

        switch passKind {
        case .draft:
            break
        case .critique:
            lines.append("")
            lines.append("CURRENT TARGET DRAFT:")
            for (index, text) in currentDraft.enumerated() {
                lines.append("\(index): \(text)")
            }
            lines.append("")
            lines.append("REVIEW CHECKLIST:")
            lines.append("- semantic drift")
            lines.append("- idiom, joke, or cultural compression loss")
            lines.append("- name/place/brand preservation")
            lines.append("- tone and register mismatch")
            lines.append("- subtitle fit and awkward phrasing")
            lines.append("- disagreement between source and reference")
        case .rewrite:
            lines.append("")
            lines.append("CURRENT TARGET DRAFT:")
            for (index, text) in currentDraft.enumerated() {
                lines.append("\(index): \(text)")
            }
            if let reviewReport {
                lines.append("")
                lines.append("CRITIQUE FINDINGS:")
                lines.append(reviewReport.summary)
                for finding in reviewReport.findings {
                    let localIndex = max(0, finding.index - batchRange.startIndex)
                    let suggested = finding.suggestedTranslation ?? ""
                    lines.append(
                        "- cue \(localIndex): [\(finding.severity.rawValue)] \(finding.kind.rawValue) | \(finding.message) | suggested: \(suggested) | referenceDecision: \(finding.referenceDecision.rawValue) | confidence: \(String(format: "%.2f", finding.confidence))"
                    )
                }
            }
        }

        if !upcomingSource.isEmpty {
            lines.append("")
            lines.append("UPCOMING SOURCE CUES:")
            for (index, text) in upcomingSource.enumerated() {
                lines.append("\(index): \(text)")
            }
        }

        if prefersShorterSubtitles {
            lines.append("")
            lines.append("SHORTENING PRIORITY:")
            lines.append("Prefer shorter subtitle wording when a literal rendering would read too long on screen.")
        }

        return lines.joined(separator: "\n")
    }

    private func plannedBatchSize(
        from startIndex: Int,
        cues: [SubtitleCue],
        results: [String],
        config: Config,
        brief: TranslationBrief,
        from sourceLanguage: LanguageOption,
        to targetLanguage: LanguageOption,
        promptPolicy: TranslationPromptPolicy,
        referenceCueSpans: [Int: NormalizedReferenceSpan]
    ) -> Int {
        let remainingCount = cues.count - startIndex
        var batchSize = min(max(1, config.batchSize), remainingCount)

        while batchSize > 1 {
            let range = TranslationBatchRange(startIndex: startIndex, endIndex: startIndex + batchSize - 1)
            let estimatedSize = estimatedPromptCharacters(
                cues: cues,
                results: results,
                batchRange: range,
                brief: brief,
                from: sourceLanguage,
                to: targetLanguage,
                config: config,
                promptPolicy: promptPolicy,
                referenceCueSpans: referenceCueSpans
            )
            if estimatedSize <= config.maxPromptCharacters {
                break
            }
            batchSize = max(1, batchSize / 2)
        }

        return batchSize
    }

    private func estimatedPromptCharacters(
        cues: [SubtitleCue],
        results: [String],
        batchRange: TranslationBatchRange,
        brief: TranslationBrief,
        from sourceLanguage: LanguageOption,
        to targetLanguage: LanguageOption,
        config: Config,
        promptPolicy: TranslationPromptPolicy,
        referenceCueSpans: [Int: NormalizedReferenceSpan]
    ) -> Int {
        let draftRequest = buildTranslationRequest(
            passKind: .draft,
            cues: cues,
            results: results,
            batchRange: batchRange,
            from: sourceLanguage,
            to: targetLanguage,
            brief: brief,
            promptPolicy: promptPolicy,
            referenceCueSpans: referenceCueSpans,
            config: config,
            prefersShorterSubtitles: false,
            currentDraft: [],
            reviewReport: nil
        )

        var total = draftRequest.messages.reduce(into: 0) { partialResult, message in
            partialResult += message.content.count
        }

        if config.passStrategy != .draftOnly {
            total *= 3
        }

        return total
    }

    private func buildTranslationBrief(cues: [SubtitleCue], episodeContext: String) -> TranslationBrief {
        return TranslationBrief(
            episodeContext: episodeContext.trimmingCharacters(in: .whitespacesAndNewlines),
            recurringTerms: extractRecurringTerms(from: cues),
            registerSummary: summarizeRegister(for: cues)
        )
    }

    private func buildPromptPolicy(config: Config, to targetLanguage: LanguageOption) -> TranslationPromptPolicy {
        let baseRole = "You are a professional subtitle translator specializing in film and TV."
        var hardRules: [String] = [
            "Use natural, conversational \(targetLanguage.displayName) suitable for subtitles.",
            "Preserve intent, humor, tone, and implied meaning instead of translating word by word.",
            "Add punctuation for rhythm and pacing when it improves readability.",
            "Keep proper nouns in original form unless the prompt explicitly approves localization.",
            "Maintain terminology consistency across the batch."
        ]

        var profileNotes: [String]
        switch config.qualityProfile {
        case .general:
            profileNotes = [
                "Prefer natural spoken subtitle phrasing over literal syntax.",
                "Keep exposition light and screen-readable."
            ]
        case .comedy:
            profileNotes = [
                "Protect punchlines, irony, and comic timing.",
                "Favor natural phrasing that lands the joke in the target language."
            ]
        case .crimeThriller:
            profileNotes = [
                "Keep tension, slang, and underworld register intact.",
                "Prefer terse, confident dialogue over explanatory wording."
            ]
        }

        if targetLanguage.code == LanguageOption.zhHans.code {
            profileNotes.append("Avoid translationese in Simplified Chinese; prefer concise colloquial subtitle phrasing.")
            hardRules.append("Do not leave unnecessary Latin-script fragments in Simplified Chinese output.")
        }

        let strictnessNotes: [String]
        switch config.strictness {
        case .balanced:
            strictnessNotes = [
                "Balance fidelity with subtitle readability.",
                "Compress only when it preserves the meaning and tone."
            ]
        case .highFidelity:
            strictnessNotes = [
                "Prioritize semantic fidelity and subtext.",
                "Do not simplify away important intent, relationships, or plot clues."
            ]
        case .subtitleFit:
            strictnessNotes = [
                "Prioritize subtitle readability and timing fit.",
                "Prefer shorter, natural lines when wording is too dense for on-screen reading."
            ]
        }

        let advancedInstructions = config.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)

        return TranslationPromptPolicy(
            baseRole: baseRole,
            hardRules: hardRules,
            profileNotes: profileNotes,
            strictnessNotes: strictnessNotes,
            advancedInstructions: advancedInstructions
        )
    }

    private func extractRecurringTerms(from cues: [SubtitleCue]) -> [String] {
        let pattern = #"\b[A-Z][A-Za-z0-9']+(?:\s+[A-Z][A-Za-z0-9']+){0,2}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var counts: [String: Int] = [:]
        for cue in cues {
            let text = cue.plainText as NSString
            let matches = regex.matches(in: cue.plainText, range: NSRange(location: 0, length: text.length))
            for match in matches {
                let term = text.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                guard term.count > 2 else { continue }
                counts[term, default: 0] += 1
            }
        }

        return counts
            .filter { $0.value > 1 }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(8)
            .map(\.key)
    }

    private func summarizeRegister(for cues: [SubtitleCue]) -> String {
        guard !cues.isEmpty else { return "" }

        let texts = cues.map(\.plainText)
        let avgWordCount = texts
            .map { $0.split(whereSeparator: \.isWhitespace).count }
            .reduce(0, +) / max(texts.count, 1)
        let exclamationCount = texts.filter { $0.contains("!") }.count
        let questionCount = texts.filter { $0.contains("?") }.count
        let profanityCount = texts.filter { $0.localizedCaseInsensitiveContains("damn") || $0.localizedCaseInsensitiveContains("hell") }.count

        var parts: [String] = []
        if avgWordCount <= 4 {
            parts.append("short, fast turn-taking dialogue")
        } else {
            parts.append("conversational subtitle dialogue")
        }
        if exclamationCount > texts.count / 6 {
            parts.append("frequent exclamations")
        }
        if questionCount > texts.count / 6 {
            parts.append("regular questioning exchanges")
        }
        if profanityCount > 0 {
            parts.append("contains mild profanity")
        }

        return parts.joined(separator: ", ")
    }

    private func neighboringTranslatedTexts(results: [String], before startIndex: Int) -> [String] {
        guard startIndex > 0 else { return [] }
        let start = max(0, startIndex - 2)
        return Array(results[start..<startIndex]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func neighboringSourceTexts(cues: [SubtitleCue], before startIndex: Int) -> [String] {
        guard startIndex > 0 else { return [] }
        let start = max(0, startIndex - 2)
        return cues[start..<startIndex].map(\.plainText)
    }

    private func neighboringSourceTexts(cues: [SubtitleCue], after endIndex: Int) -> [String] {
        guard endIndex + 1 < cues.count else { return [] }
        let end = min(cues.count, endIndex + 3)
        return cues[(endIndex + 1)..<end].map(\.plainText)
    }

    private func sourceTexts(in cues: [SubtitleCue], range: TranslationBatchRange) -> [String] {
        Array(cues[range.startIndex...range.endIndex]).map(\.plainText)
    }

    private func referenceSpans(
        in cues: [SubtitleCue],
        range: TranslationBatchRange,
        referenceCueSpans: [Int: NormalizedReferenceSpan]
    ) -> [Int: NormalizedReferenceSpan] {
        var output: [Int: NormalizedReferenceSpan] = [:]
        for (offset, cue) in cues[range.startIndex...range.endIndex].enumerated() {
            if let value = referenceCueSpans[cue.id] {
                output[offset] = value
            }
        }
        return output
    }

    private func normalizeInitialResults(_ initialResults: [String], totalCount: Int) -> [String] {
        var normalized = Array(repeating: "", count: totalCount)
        for (index, text) in initialResults.enumerated() where index < totalCount {
            normalized[index] = text
        }
        return normalized
    }

    private func parseTranslationResponse(_ response: String, expectedCount: Int) throws -> [String] {
        guard let data = response.data(using: .utf8) else {
            throw WorkflowError.networkError("Translation response was not valid UTF-8.")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return try extractOrderedResults(from: json, expectedCount: expectedCount)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let normalized = json.reduce(into: [String: String]()) { partialResult, entry in
                if let value = entry.value as? String {
                    partialResult[entry.key] = value
                }
            }
            return try extractOrderedResults(from: normalized, expectedCount: expectedCount)
        }

        throw WorkflowError.networkError("Translation did not return the required JSON object.")
    }

    private func extractOrderedResults(from json: [String: String], expectedCount: Int) throws -> [String] {
        var results = Array(repeating: "", count: expectedCount)
        for index in 0..<expectedCount {
            let key = String(index)
            guard let value = json[key] else {
                throw WorkflowError.networkError("Translation JSON was missing index \(index).")
            }
            results[index] = value
        }
        return results
    }

    private func parseReviewReport(
        _ response: String,
        cues: [SubtitleCue],
        batchRange: TranslationBatchRange,
        expectedCount: Int,
        referenceCueSpans: [Int: NormalizedReferenceSpan],
        confidenceThreshold: Double
    ) throws -> TranslationReviewReport {
        guard let data = response.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkflowError.networkError("Translation critique did not return valid JSON.")
        }

        let summary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "QA review completed."
        let findingsJSON = json["findings"] as? [[String: Any]] ?? []

        let findings = findingsJSON.compactMap { entry -> TranslationCueFinding? in
            let rawIndex = entry["index"]
            let indexValue: Int?
            if let value = rawIndex as? Int {
                indexValue = value
            } else if let value = rawIndex as? String {
                indexValue = Int(value)
            } else {
                indexValue = nil
            }

            guard let localIndex = indexValue,
                  (0..<expectedCount).contains(localIndex) else {
                return nil
            }

            let globalIndex = batchRange.startIndex + localIndex
            let severity = TranslationCueFindingSeverity(rawValue: (entry["severity"] as? String) ?? "") ?? .major
            let kind = TranslationCueFindingKind(rawValue: (entry["kind"] as? String) ?? "") ?? .semanticDrift
            let message = (entry["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Review flagged this cue."
            let suggestedTranslation = (entry["suggestedTranslation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let referenceDecisionRaw = (entry["referenceDecision"] as? String) ?? ReferenceConflictDecision.keepSource.rawValue
            var referenceDecision = ReferenceConflictDecision(rawValue: referenceDecisionRaw) ?? .keepSource
            let confidenceValue: Double
            if let confidence = entry["confidence"] as? Double {
                confidenceValue = confidence
            } else if let confidence = entry["confidence"] as? NSNumber {
                confidenceValue = confidence.doubleValue
            } else if let confidence = entry["confidence"] as? String, let doubleValue = Double(confidence) {
                confidenceValue = doubleValue
            } else {
                confidenceValue = referenceDecision == .overrideWithReference ? 0.5 : 0
            }

            if referenceDecision == .overrideWithReference {
                let sourceCueID = cues[globalIndex].id
                let hasReference = referenceCueSpans[sourceCueID] != nil
                if confidenceValue < confidenceThreshold || !hasReference {
                    referenceDecision = hasReference ? .supportReference : .keepSource
                }
            }

            return TranslationCueFinding(
                index: globalIndex,
                severity: severity,
                kind: kind,
                message: message,
                suggestedTranslation: suggestedTranslation?.isEmpty == true ? nil : suggestedTranslation,
                referenceDecision: referenceDecision,
                confidence: confidenceValue
            )
        }

        return TranslationReviewReport(
            summary: summary.isEmpty ? "QA review completed." : summary,
            findings: findings
        )
    }

    private func buildReferenceCueSpans(
        sourceCues: [SubtitleCue],
        sourceLanguage: LanguageOption,
        referenceDocument: SubtitleDocument?
    ) -> [Int: NormalizedReferenceSpan] {
        guard let referenceDocument, !referenceDocument.cues.isEmpty else { return [:] }

        let syntheticSource = SubtitleDocument(
            language: sourceLanguage,
            format: .srt,
            origin: .unknown,
            sourceLabel: "source",
            cues: sourceCues
        )

        let normalization = aligner.normalizeSecondaryToSource(source: syntheticSource, target: referenceDocument)
        guard normalization.isReliable else {
            return [:]
        }
        return normalization.referenceSpansBySourceCueID
    }

    private func combinedReviewReport(from findings: [TranslationCueFinding]) -> TranslationReviewReport {
        let sortedFindings = findings.sorted { lhs, rhs in
            if lhs.index == rhs.index {
                return lhs.confidence > rhs.confidence
            }
            return lhs.index < rhs.index
        }
        let flaggedCueCount = Set(sortedFindings.map(\.index)).count
        let overrideCount = sortedFindings.filter(\.isReferenceOverride).count
        let summary: String
        if sortedFindings.isEmpty {
            summary = "QA review passed without flagged cues."
        } else {
            summary = "QA review flagged \(flaggedCueCount) cue(s), including \(overrideCount) high-confidence reference-assisted override(s)."
        }
        return TranslationReviewReport(summary: summary, findings: sortedFindings)
    }

    private func validateTranslationBatch(
        sourceTexts: [String],
        translatedTexts: [String],
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        config: Config
    ) throws {
        guard translatedTexts.count == sourceTexts.count else {
            throw WorkflowError.networkError("Translation returned an unexpected cue count.")
        }

        var emptyCount = 0
        var unchangedCount = 0
        var overlongCount = 0

        for (source, translated) in zip(sourceTexts, translatedTexts) {
            let normalizedTranslation = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)

            if normalizedTranslation.isEmpty {
                emptyCount += 1
                continue
            }

            if normalizedTranslation.caseInsensitiveCompare(normalizedSource) == .orderedSame,
               sourceLanguage != targetLanguage {
                unchangedCount += 1
            }

            let lines = normalizedTranslation.split(separator: "\n", omittingEmptySubsequences: false)
            let longestLineCount = lines.map(\.count).max() ?? normalizedTranslation.count
            if lines.count > config.maxLinesPerCue || longestLineCount > config.targetCharactersPerLine + 10 {
                overlongCount += 1
            }
        }

        if emptyCount > 0 {
            throw WorkflowError.runtime("Translation returned empty subtitle cues.")
        }

        if unchangedCount == sourceTexts.count, sourceLanguage != targetLanguage {
            throw WorkflowError.runtime("Translation appears unchanged from the source text.")
        }

        if overlongCount > max(1, sourceTexts.count / 3) {
            throw WorkflowError.runtime("Translation batch is too long for subtitle reading.")
        }
    }
}
