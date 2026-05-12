import Foundation
import OSLog

struct SileroVADService: VADServicing {
    private let processRunner: ProcessRunner
    private let toolRegistry: MediaToolRegistry
    private let logger = Logger(subsystem: "com.xiaodong.SubtitleStudio", category: "VAD")

    private let adPatterns: [String] = [
        "yts", "yify", "downloaded from", "official",
        "subscribe", "bit.ly", "www.", "http",
        "torrent", "ettv", "rarbg", "scenes"
    ]
    private let maxAdDurationMilliseconds = 5_000
    private let maxAdTextLength = 80

    init(processRunner: ProcessRunner = ProcessRunner(),
         toolRegistry: MediaToolRegistry = MediaToolRegistry()) {
        self.processRunner = processRunner
        self.toolRegistry = toolRegistry
    }

    // ── Cue Classification ──────────────────────────────────────

    func classifyCues(in document: SubtitleDocument, trackTitle: String?) -> [CueKind] {
        let trackIsSDH = trackTitle.map { t in
            let lower = t.lowercased()
            return lower.contains("sdh") || lower.contains("hearing impaired")
                || lower.contains("closed caption") || lower.contains("[cc]")
        } ?? false

        let trackIsForced = trackTitle.map { t in
            t.lowercased().contains("forced")
        } ?? false

        if trackIsForced {
            logger.debug("Track classified as Forced Narrative based on title")
            return document.cues.map { _ in .forcedNarrative }
        }

        var counts = (dialogue: 0, sdh: 0, ad: 0, forced: 0)
        let kinds = document.cues.map { cue in
            if isAdCue(cue) { counts.ad += 1; return CueKind.ad }
            if trackIsSDH || hasSDHPatterns(cue.plainText) { counts.sdh += 1; return CueKind.sdh }
            counts.dialogue += 1; return CueKind.dialogue
        }
        logger.debug("Cue classification: dialogue=\(counts.dialogue) sdh=\(counts.sdh) ad=\(counts.ad)")
        return kinds
    }

    private func isAdCue(_ cue: SubtitleCue) -> Bool {
        guard cue.durationMilliseconds <= maxAdDurationMilliseconds,
              cue.plainText.count < maxAdTextLength else { return false }
        return adPatterns.contains { cue.plainText.lowercased().contains($0) }
    }

    private func hasSDHPatterns(_ text: String) -> Bool {
        let ns = NSRange(text.startIndex..., in: text)
        if (try? NSRegularExpression(pattern: #"^\[.*?\]"#).firstMatch(in: text, range: ns)) != nil { return true }
        if (try? NSRegularExpression(pattern: #"^\(.*?\)"#).firstMatch(in: text, range: ns)) != nil { return true }
        if text.contains("\u{266A}") || text.contains("\u{266B}") { return true }
        if (try? NSRegularExpression(pattern: #"^[A-Z][A-Za-z]+:"#).firstMatch(in: text, range: ns)) != nil { return true }
        if (try? NSRegularExpression(pattern: #"^[A-Z]{2,}$"#).firstMatch(in: text, range: ns)) != nil { return true }
        return false
    }

    // ── VAD Analysis ────────────────────────────────────────────

    func analyze(
        videoURL: URL,
        source: SubtitleDocument,
        target: SubtitleDocument,
        audioTrackIndex: Int
    ) async throws -> VADArbitrationResult {
        let startTime = Date()

        guard let ffmpegPath = toolRegistry.executablePath(for: .ffmpeg) else {
            logger.error("ffmpeg not found via MediaToolRegistry")
            throw WorkflowError.dependencyUnavailable("ffmpeg is required for voice analysis but was not found.")
        }
        logger.info("Using ffmpeg at \(ffmpegPath)")

        let cueKindsSource = classifyCues(in: source, trackTitle: nil)
        let cueKindsTarget = classifyCues(in: target, trackTitle: nil)

        let dialogueCues = zip(source.cues, cueKindsSource).filter { $0.1 == .dialogue }.map(\.0)
            + zip(target.cues, cueKindsTarget).filter { $0.1 == .dialogue }.map(\.0)

        let ranges = mergeTimeRanges(from: dialogueCues, padding: 2_000, maxGap: 3_000)
        logger.info("Merged \(dialogueCues.count) dialogue cues into \(ranges.count) audio extraction ranges")

        guard !ranges.isEmpty else {
            logger.warning("No dialogue cues found for VAD analysis")
            return .empty
        }

        let allSegments: [VADSpeechSegment] = try await withThrowingTaskGroup(
            of: [VADSpeechSegment].self
        ) { group in
            for (idx, range) in ranges.enumerated() {
                group.addTask { [self] in
                    let durSec = Double(range.duration) / 1_000
                    logger.debug("Range \(idx + 1)/\(ranges.count): start=\(range.start)ms duration=\(durSec)s")
                    do {
                        let wav = try await extractAudio(
                            videoURL: videoURL,
                            startMilliseconds: range.start,
                            durationMilliseconds: range.duration,
                            audioTrackIndex: audioTrackIndex,
                            ffmpegPath: ffmpegPath
                        )
                        logger.debug("Range \(idx + 1): extracted \(wav.count) bytes of raw audio")
                        let segments = detectSpeech(from: wav, baseOffset: range.start)
                        logger.debug("Range \(idx + 1): detected \(segments.count) speech segments")
                        return segments
                    } catch {
                        logger.error("Range \(idx + 1) failed: \(error.localizedDescription)")
                        return []
                    }
                }
            }
            var results: [VADSpeechSegment] = []
            for try await segments in group { results.append(contentsOf: segments) }
            return results
        }

        logger.info("Total speech segments detected: \(allSegments.count)")

        let sourceScores = scoreCues(source.cues, against: allSegments)
        let targetScores = scoreCues(target.cues, against: allSegments)

        let sourceAvg = sourceScores.isEmpty ? 0 : sourceScores.values.map(\.speechOverlapRatio).reduce(0, +) / Double(sourceScores.count)
        let targetAvg = targetScores.isEmpty ? 0 : targetScores.values.map(\.speechOverlapRatio).reduce(0, +) / Double(targetScores.count)
        logger.info("VAD complete: sourceAvg=\(String(format: "%.2f", sourceAvg)) targetAvg=\(String(format: "%.2f", targetAvg))")

        return VADArbitrationResult(
            sourceScores: sourceScores,
            targetScores: targetScores,
            speechSegments: allSegments,
            elapsedSeconds: Date().timeIntervalSince(startTime)
        )
    }

    // ── Audio Extraction ────────────────────────────────────────

    private func extractAudio(
        videoURL: URL,
        startMilliseconds: Int,
        durationMilliseconds: Int,
        audioTrackIndex: Int,
        ffmpegPath: String
    ) async throws -> Data {
        let ss = String(format: "%.3f", Double(startMilliseconds) / 1_000)
        let dur = String(format: "%.3f", Double(durationMilliseconds) / 1_000)
        let args = [
            "-ss", ss,
            "-i", videoURL.path,
            "-t", dur,
            "-map", "0:a:\(audioTrackIndex)",
            "-ac", "1",
            "-ar", "16000",
            "-f", "s16le",
            "-vn",
            "pipe:1"
        ]

        let result = try await processRunner.runDetailed(
            executable: ffmpegPath,
            arguments: args,
            timeout: 30
        )

        if !result.stderr.isEmpty, let errText = String(data: result.stderr, encoding: .utf8), !errText.isEmpty {
            logger.debug("ffmpeg stderr: \(errText.prefix(200))")
        }

        guard !result.stdout.isEmpty else {
            logger.warning("ffmpeg produced no audio data for range start=\(ss)s dur=\(dur)s track=\(audioTrackIndex)")
            throw WorkflowError.runtime("No audio data extracted at \(ss)s (track \(audioTrackIndex)). The video may not have audio at this position or the audio track index may be wrong.")
        }

        return result.stdout
    }

    // ── RMS Energy VAD ──────────────────────────────────────────

    private func detectSpeech(from raw: Data, baseOffset: Int) -> [VADSpeechSegment] {
        guard raw.count > 0 else { return [] }
        let samples = raw.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        guard samples.count > 0 else { return [] }

        let windowSize = 160
        let threshold: Double = 200

        var segments: [VADSpeechSegment] = []
        var speechStart: Int?
        var speechEnd: Int?
        var lastRms: Double = 0

        for i in stride(from: 0, to: samples.count - windowSize, by: windowSize / 2) {
            let window = samples[i..<min(i + windowSize, samples.count)]
            let rms = sqrt(window.reduce(0) { $0 + Double($1) * Double($1) } / Double(window.count))
            let t = baseOffset + Int(Double(i) / 16_000 * 1_000)

            if rms > threshold {
                if speechStart == nil { speechStart = t }
                speechEnd = t + Int(Double(windowSize) / 16_000 * 1_000)
            } else if let start = speechStart, let end = speechEnd, end - start >= 200 {
                segments.append(VADSpeechSegment(startMilliseconds: start, endMilliseconds: end, confidence: min(1, lastRms / 1000)))
                speechStart = nil
                speechEnd = nil
            }
            lastRms = rms
        }

        if let start = speechStart, let end = speechEnd, end - start >= 200 {
            segments.append(VADSpeechSegment(startMilliseconds: start, endMilliseconds: end, confidence: 0.8))
        }

        return segments
    }

    // ── Cue Scoring ─────────────────────────────────────────────

    private func scoreCues(_ cues: [SubtitleCue], against segments: [VADSpeechSegment]) -> [Int: CueVADScore] {
        var scores: [Int: CueVADScore] = [:]
        for cue in cues {
            guard cue.durationMilliseconds > 0 else { scores[cue.id] = CueVADScore.none; continue }
            var bestOverlap = 0
            var bestSeg: VADSpeechSegment?
            for seg in segments {
                let o = max(0, min(cue.endMilliseconds, seg.endMilliseconds) - max(cue.startMilliseconds, seg.startMilliseconds))
                if o > bestOverlap { bestOverlap = o; bestSeg = seg }
            }
            scores[cue.id] = CueVADScore(
                cueID: cue.id,
                speechOverlapRatio: min(1, Double(bestOverlap) / Double(cue.durationMilliseconds)),
                startDeltaMilliseconds: bestSeg.map { abs(cue.startMilliseconds - $0.startMilliseconds) },
                endDeltaMilliseconds: bestSeg.map { abs(cue.endMilliseconds - $0.endMilliseconds) },
                hasSpeech: bestSeg != nil
            )
        }
        return scores
    }

    // ── Range Merging ───────────────────────────────────────────

    private func mergeTimeRanges(
        from cues: [SubtitleCue],
        padding: Int,
        maxGap: Int
    ) -> [(start: Int, duration: Int)] {
        guard !cues.isEmpty else { return [] }
        let sorted = cues.sorted { $0.startMilliseconds < $1.startMilliseconds }
        var ranges: [(Int, Int)] = []
        for cue in sorted {
            let s = max(0, cue.startMilliseconds - padding)
            let e = cue.endMilliseconds + padding
            if let last = ranges.last, s - last.1 <= maxGap {
                ranges[ranges.count - 1] = (last.0, e)
            } else {
                ranges.append((s, e))
            }
        }
        return ranges.map { (start: $0.0, duration: $0.1 - $0.0) }
    }
}
