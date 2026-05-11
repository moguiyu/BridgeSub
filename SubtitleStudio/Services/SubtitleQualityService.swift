import Foundation

struct SubtitleQualityService: SubtitleQualityScoringServicing {
    private let aligner = SubtitleAligner()

    func evaluate(
        source: SubtitleDocument,
        candidate: SubtitleDocument,
        targetLanguage: LanguageOption,
        alignmentReport: AlignmentReport? = nil
    ) -> SubtitleQualityReport {
        let alignmentReport = alignmentReport ?? aligner.align(source: source, target: candidate)

        guard !source.cues.isEmpty, !candidate.cues.isEmpty else {
            return SubtitleQualityReport(
                decision: .reject,
                score: 0,
                notes: ["Subtitle is empty."],
                metrics: [:],
                alignmentReport: alignmentReport
            )
        }

        let cueRatio = min(Double(candidate.cues.count), Double(source.cues.count)) / max(Double(candidate.cues.count), Double(source.cues.count))
        let overlapRatio = timingOverlapRatio(source: source.cues, target: candidate.cues)
        let nonEmptyRatio = candidate.cues.nonEmptyCueRatio
        let repeatedLineRatio = repeatedLineRatio(in: candidate.cues)
        let chineseConfidence = chineseConfidence(in: candidate.cues, targetLanguage: targetLanguage)
        let latinLeakRatio = latinLeakRatio(in: candidate.cues, targetLanguage: targetLanguage)
        let matchedCueRatio = alignmentReport.matchedCueRatio
        let lowConfidenceCueRatio = alignmentReport.lowConfidenceCueRatio
        let unmatchedCueRatio = alignmentReport.unmatchedCueRatio
        let medianStartDelta = alignmentReport.medianStartDeltaMilliseconds
        let averageAlignmentConfidence = alignmentReport.averageConfidence

        var score = 1.0
        score -= penalty(forCueRatio: cueRatio)
        score -= max(0, 0.35 - overlapRatio)
        score -= max(0, 0.8 - nonEmptyRatio)
        score -= max(0, repeatedLineRatio - 0.18)
        score -= max(0, latinLeakRatio - 0.45) * 0.6
        score -= max(0, 0.75 - chineseConfidence) * 0.8
        score -= max(0, 0.82 - matchedCueRatio) * 0.9
        score -= lowConfidenceCueRatio * 0.75
        score -= unmatchedCueRatio * 0.6
        score -= max(0, medianStartDelta - 250) / 2_000
        score -= max(0, 0.72 - averageAlignmentConfidence) * 0.8
        score = min(max(score, 0), 1)

        var notes: [String] = []
        if cueRatio < 0.7 {
            notes.append("Cue-count mismatch is too large.")
        }
        if overlapRatio < 0.35 {
            notes.append("Timing overlap with the source subtitle is weak.")
        }
        if nonEmptyRatio < 0.8 {
            notes.append("Many cues are empty or whitespace-only.")
        }
        if repeatedLineRatio > 0.18 {
            notes.append("The subtitle repeats the same lines too often.")
        }
        if targetLanguage.code == LanguageOption.zhHans.code && chineseConfidence < 0.75 {
            notes.append("Detected text does not look like strong Simplified Chinese coverage.")
        }
        if latinLeakRatio > 0.45 {
            notes.append("Too much Latin text remains in the target subtitle.")
        }
        if matchedCueRatio < 0.82 {
            notes.append("Too many cues only weakly align to the source timing.")
        }
        if lowConfidenceCueRatio > 0.08 {
            notes.append("Several cue matches have low confidence and may drift by one line.")
        }
        if medianStartDelta > 250 {
            notes.append("Median cue start offset is high, suggesting timing drift.")
        }
        if notes.isEmpty {
            notes.append("Quality gate passed the heuristic checks.")
        }

        if let driftMs = alignmentReport.detectedTimingOffsetMilliseconds {
            let sign = driftMs > 0 ? "+" : ""
            notes.append("Timing drift: \(sign)\(driftMs)ms detected and corrected")
        }

        let orphanCount = alignmentReport.orphanedTargetCueIDs.count
        if orphanCount > 0 {
            let matchedCount = alignmentReport.matches.filter { $0.targetCueID != nil }.count
            let totalTarget = matchedCount + orphanCount
            let coverageAfter = totalTarget > 0
                ? Double(matchedCount + orphanCount) / Double(totalTarget)
                : 1.0
            notes.append("\(orphanCount) secondary cues recovered as secondary-only (coverage: \(Int((coverageAfter * 100).rounded()))%)")
        }

        let decision: SubtitleDecision
        if score >= 0.78 {
            decision = .accept
        } else if score >= 0.55 {
            decision = .review
        } else {
            decision = .reject
        }

        return SubtitleQualityReport(
            decision: decision,
            score: score,
            notes: notes,
            metrics: [
                "cueRatio": cueRatio,
                "overlapRatio": overlapRatio,
                "nonEmptyRatio": nonEmptyRatio,
                "repeatedLineRatio": repeatedLineRatio,
                "chineseConfidence": chineseConfidence,
                "latinLeakRatio": latinLeakRatio,
                "matchedCueRatio": matchedCueRatio,
                "lowConfidenceCueRatio": lowConfidenceCueRatio,
                "unmatchedCueRatio": unmatchedCueRatio,
                "medianStartDeltaMilliseconds": medianStartDelta,
                "averageAlignmentConfidence": averageAlignmentConfidence
            ],
            alignmentReport: alignmentReport
        )
    }

    private func penalty(forCueRatio ratio: Double) -> Double {
        switch ratio {
        case ..<0.45: return 0.45
        case ..<0.60: return 0.28
        case ..<0.75: return 0.14
        default: return 0
        }
    }

    private func timingOverlapRatio(source: [SubtitleCue], target: [SubtitleCue]) -> Double {
        let comparisons = source.prefix(120).map { cue -> Double in
            let overlap = target
                .map { max(0, min(cue.endMilliseconds, $0.endMilliseconds) - max(cue.startMilliseconds, $0.startMilliseconds)) }
                .max() ?? 0

            guard cue.durationMilliseconds > 0 else { return 0 }
            return min(1, Double(overlap) / Double(cue.durationMilliseconds))
        }

        guard !comparisons.isEmpty else { return 0 }
        return comparisons.reduce(0, +) / Double(comparisons.count)
    }

    private func repeatedLineRatio(in cues: [SubtitleCue]) -> Double {
        let normalizedLines = cues.map { $0.plainText.normalizedSubtitleText }.filter { !$0.isEmpty }
        guard !normalizedLines.isEmpty else { return 1 }
        let uniqueCount = Set(normalizedLines).count
        return 1 - (Double(uniqueCount) / Double(normalizedLines.count))
    }

    private func chineseConfidence(in cues: [SubtitleCue], targetLanguage: LanguageOption) -> Double {
        guard targetLanguage.code == LanguageOption.zhHans.code else { return 1 }
        let sample = cues.prefix(120).map(\.plainText).joined(separator: " ")
        guard !sample.isEmpty else { return 0 }

        let scalars = sample.unicodeScalars
        let hanCount = scalars.filter { 0x4E00...0x9FFF ~= $0.value }.count
        let simplifiedSignal = sample.looksLikeSimplifiedChinese ? 0.2 : 0
        return min(1, (Double(hanCount) / Double(max(sample.count, 1))) * 4.5 + simplifiedSignal)
    }

    private func latinLeakRatio(in cues: [SubtitleCue], targetLanguage: LanguageOption) -> Double {
        guard targetLanguage.code == LanguageOption.zhHans.code else { return 0 }
        let sample = cues.prefix(160).map(\.plainText).joined(separator: " ")
        guard !sample.isEmpty else { return 1 }
        let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let latinCount = letters.filter { ("A"..."Z").contains(String($0)) || ("a"..."z").contains(String($0)) }.count
        return Double(latinCount) / Double(max(letters.count, 1))
    }
}
