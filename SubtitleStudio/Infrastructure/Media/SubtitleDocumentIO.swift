import Foundation
import OSLog
import SubtitleKit

struct SubtitleDocumentIOService: SubtitleDocumentIOServicing {
    private static let logger = Logger(subsystem: "com.xiaodong.SubtitleStudio", category: "SubtitleIO")

    private let processRunner: ProcessRunner
    private let cache: SubtitleDocumentCache
    private let toolRegistry: MediaToolRegistry
    private let embeddedExtractionTimeout: TimeInterval

    init(
        processRunner: ProcessRunner,
        cache: SubtitleDocumentCache = SubtitleDocumentCache(),
        toolRegistry: MediaToolRegistry,
        embeddedExtractionTimeout: TimeInterval = 60
    ) {
        self.processRunner = processRunner
        self.cache = cache
        self.toolRegistry = toolRegistry
        self.embeddedExtractionTimeout = embeddedExtractionTimeout
    }

    func loadDocument(for candidate: SubtitleCandidate, videoURL: URL) async throws -> SubtitleDocument {
        let cacheKey = cacheKey(for: candidate, videoURL: videoURL)
        if let cachedDocument = await cache.document(for: cacheKey) {
            Self.logger.debug("Using cached subtitle document for candidate \(candidate.id, privacy: .public)")
            return cachedDocument
        }

        let document: SubtitleDocument
        switch candidate.locator {
        case .file(let url):
            document = try loadSubtitle(
                at: url,
                language: candidate.language,
                origin: candidate.origin,
                label: candidate.sourceLabel
            )
        case .embedded(let trackIndex):
            if let embeddedTrack = candidate.embeddedTrack, !embeddedTrack.isTextBased {
                throw WorkflowError.unsupported(
                    "Embedded subtitle track `\(embeddedTrack.displayLabel)` is image-based. OCR is not implemented yet."
                )
            }
            let codec = candidate.embeddedTrack?.codecName ?? "unknown"
            Self.logger.info(
                "Loading embedded subtitle candidate \(candidate.id, privacy: .public), track \(trackIndex), language \(candidate.language.storageCode, privacy: .public), codec \(codec, privacy: .public), video \(videoURL.path, privacy: .public)"
            )
            document = try await extractEmbeddedSubtitle(
                from: videoURL,
                trackIndex: trackIndex,
                language: candidate.language,
                label: candidate.sourceLabel,
                embeddedTrack: candidate.embeddedTrack
            )
        case .generated:
            throw WorkflowError.unsupported("Generated subtitle candidates are not wired yet.")
        }

        await cache.store(document, for: cacheKey)
        return document
    }

    func extractorKind(for candidate: SubtitleCandidate, videoURL: URL) -> EmbeddedSubtitleExtractorKind? {
        guard case .embedded = candidate.locator else { return nil }
        return preferredExtractorKind(for: candidate, videoURL: videoURL)
    }

    func importFallbackSubtitle(at url: URL, language: LanguageOption, roleOrigin: SubtitleOriginKind) throws -> SubtitleCandidate {
        try importFallbackSubtitleWithDocument(at: url, language: language, roleOrigin: roleOrigin).candidate
    }

    func importFallbackSubtitleWithDocument(at url: URL, language: LanguageOption, roleOrigin: SubtitleOriginKind) throws -> ImportedSubtitleCandidate {
        let document = try loadSubtitle(at: url, language: language, origin: roleOrigin, label: url.lastPathComponent)
        let format = SubtitleFormatKind(rawValue: url.pathExtension.lowercased()) ?? .unknown
        let rankingScore: Double
        switch roleOrigin {
        case .embedded:
            rankingScore = 1.0
        case .localFile:
            rankingScore = 1.1
        case .openSubtitles:
            rankingScore = 0.75
        case .llmTranslation:
            rankingScore = 0.65
        case .mergedOutput, .unknown:
            rankingScore = 0.6
        }
        let candidate = SubtitleCandidate(
            id: UUID().uuidString,
            language: language,
            format: format,
            origin: roleOrigin,
            sourceLabel: url.lastPathComponent,
            availability: .available,
            loadState: .loaded,
            locator: .file(url),
            rankingScore: rankingScore,
            fileURL: url,
            embeddedTrack: nil
        )
        return ImportedSubtitleCandidate(candidate: candidate, document: document)
    }

    func saveDocument(_ document: SubtitleDocument, to url: URL) throws {
        let entries = document.cues.map { cue in
            SubtitleEntry.cue(SubtitleKit.SubtitleCue(
                id: cue.id,
                startTime: cue.startMilliseconds,
                endTime: cue.endMilliseconds,
                rawText: cue.rawText,
                plainText: cue.plainText
            ))
        }
        let subtitleDoc = SubtitleKit.SubtitleDocument(
            formatName: document.format.fileExtension,
            entries: entries
        )
        let subtitle = SubtitleKit.Subtitle(
            document: subtitleDoc,
            sourceLineEnding: .lf,
            sourceHadByteOrderMark: false
        )
        try subtitle.save(to: url)
    }

    private func loadSubtitle(
        at url: URL,
        language: LanguageOption,
        origin: SubtitleOriginKind,
        label: String
    ) throws -> SubtitleDocument {
        let subtitle = try Subtitle.load(from: url)
        let format = SubtitleFormatKind(rawValue: url.pathExtension.lowercased()) ?? .unknown
        return mapDocument(
            subtitle,
            language: language,
            format: format,
            origin: origin,
            label: label
        )
    }

    private func extractEmbeddedSubtitle(
        from videoURL: URL,
        trackIndex: Int,
        language: LanguageOption,
        label: String,
        embeddedTrack: EmbeddedSubtitleTrack?
    ) async throws -> SubtitleDocument {
        if preferredExtractorKind(for: embeddedTrack, videoURL: videoURL) == .mkvextract {
            do {
                Self.logger.info("Starting mkvextract for embedded subtitle track \(trackIndex), video \(videoURL.path, privacy: .public)")
                return try await extractEmbeddedSubtitleWithMKVExtract(
                    from: videoURL,
                    trackIndex: trackIndex,
                    language: language,
                    label: label,
                    format: subtitleFormat(for: embeddedTrack)
                )
            } catch {
                Self.logger.error("mkvextract failed for subtitle track \(trackIndex): \(error.localizedDescription, privacy: .public)")
                if case WorkflowError.processTimedOut = error {
                    throw error
                }
                Self.logger.info("Falling back to ffmpeg for embedded subtitle track \(trackIndex)")
            }
        }

        Self.logger.info("Starting ffmpeg subtitle extraction for embedded subtitle track \(trackIndex), video \(videoURL.path, privacy: .public)")
        return try await extractEmbeddedSubtitleWithFFmpeg(
            from: videoURL,
            trackIndex: trackIndex,
            language: language,
            label: label
        )
    }

    private func extractEmbeddedSubtitleWithFFmpeg(
        from videoURL: URL,
        trackIndex: Int,
        language: LanguageOption,
        label: String
    ) async throws -> SubtitleDocument {
        guard let ffmpeg = toolRegistry.executablePath(for: .ffmpeg) else {
            throw WorkflowError.dependencyUnavailable("`ffmpeg` is not installed.")
        }
        let result = try await processRunner.runDetailed(
            executable: ffmpeg,
            arguments: [
                "-v", "error",
                "-i", videoURL.path,
                "-map", "0:\(trackIndex)",
                "-f", "webvtt",
                "-"
            ],
            timeout: embeddedExtractionTimeout
        )
        Self.logger.info(
            "ffmpeg extracted subtitle track \(trackIndex) in \(result.elapsedTime, format: .fixed(precision: 2))s with \(result.stdout.count) output bytes"
        )
        guard let vttText = String(data: result.stdout, encoding: .utf8) else {
            throw WorkflowError.runtime("Unable to decode process output as UTF-8 text.")
        }
        let subtitle = try Subtitle.parse(vttText, format: .vtt)
        return mapDocument(
            subtitle,
            language: language,
            format: .vtt,
            origin: .embedded,
            label: label
        )
    }

    private func extractEmbeddedSubtitleWithMKVExtract(
        from videoURL: URL,
        trackIndex: Int,
        language: LanguageOption,
        label: String,
        format: SubtitleFormatKind
    ) async throws -> SubtitleDocument {
        guard let mkvextract = toolRegistry.executablePath(for: .mkvextract) else {
            throw WorkflowError.dependencyUnavailable("`mkvextract` is not installed.")
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.fileExtension)

        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let result = try await processRunner.runDetailed(
            executable: mkvextract,
            arguments: [
                "tracks",
                videoURL.path,
                "\(trackIndex):\(temporaryURL.path)"
            ],
            timeout: embeddedExtractionTimeout
        )
        Self.logger.info(
            "mkvextract extracted subtitle track \(trackIndex) in \(result.elapsedTime, format: .fixed(precision: 2))s to \(temporaryURL.path, privacy: .public)"
        )

        return try loadSubtitle(
            at: temporaryURL,
            language: language,
            origin: .embedded,
            label: label
        )
    }

    private func preferredExtractorKind(for candidate: SubtitleCandidate, videoURL: URL) -> EmbeddedSubtitleExtractorKind {
        preferredExtractorKind(for: candidate.embeddedTrack, videoURL: videoURL)
    }

    private func preferredExtractorKind(for embeddedTrack: EmbeddedSubtitleTrack?, videoURL: URL) -> EmbeddedSubtitleExtractorKind {
        guard videoURL.pathExtension.lowercased() == "mkv",
              let embeddedTrack,
              embeddedTrack.isTextBased,
              subtitleFormat(for: embeddedTrack) != .unknown,
              toolRegistry.executablePath(for: .mkvextract) != nil else {
            return .ffmpeg
        }
        return .mkvextract
    }

    private func subtitleFormat(for embeddedTrack: EmbeddedSubtitleTrack?) -> SubtitleFormatKind {
        guard let embeddedTrack else { return .unknown }
        let codec = embeddedTrack.codecName.lowercased()
        switch codec {
        case "subrip", "srt":
            return .srt
        case "ass", "ssa":
            return .ass
        case "webvtt":
            return .vtt
        default:
            return .unknown
        }
    }

    private func mapDocument(
        _ subtitle: Subtitle,
        language: LanguageOption,
        format: SubtitleFormatKind,
        origin: SubtitleOriginKind,
        label: String
    ) -> SubtitleDocument {
        let cues = subtitle.cues.map {
            SubtitleCue(
                id: $0.id,
                startMilliseconds: $0.startTime,
                endMilliseconds: $0.endTime,
                rawText: $0.rawText,
                plainText: $0.plainText
            )
        }

        return SubtitleDocument(
            language: language,
            format: format,
            origin: origin,
            sourceLabel: label,
            cues: cues
        )
    }

    private func cacheKey(for candidate: SubtitleCandidate, videoURL: URL) -> String {
        switch candidate.locator {
        case .file(let url):
            return "file:\(url.standardizedFileURL.path)"
        case .embedded(let trackIndex):
            return "embedded:\(videoURL.standardizedFileURL.path)#\(trackIndex)"
        case .generated:
            return "generated:\(candidate.id)"
        }
    }
}

actor SubtitleDocumentCache {
    private var documents: [String: SubtitleDocument] = [:]
    private var accessOrder: [String] = []
    private let maxSize: Int

    init(maxSize: Int = 10) {
        self.maxSize = maxSize
    }

    func document(for key: String) -> SubtitleDocument? {
        if let doc = documents[key] {
            // Move to end (most recently used)
            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
                accessOrder.append(key)
            }
            return doc
        }
        return nil
    }

    func store(_ document: SubtitleDocument, for key: String) {
        if documents[key] != nil {
            // Update existing, move to end
            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
                accessOrder.append(key)
            }
        } else {
            // Add new entry
            if accessOrder.count >= maxSize {
                // Remove least recently used (first element)
                let lruKey = accessOrder.removeFirst()
                documents.removeValue(forKey: lruKey)
            }
            accessOrder.append(key)
        }
        documents[key] = document
    }

    func clear() {
        documents.removeAll()
        accessOrder.removeAll()
    }
}
