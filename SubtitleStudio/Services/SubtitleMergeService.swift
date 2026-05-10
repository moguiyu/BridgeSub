import Foundation

struct SubtitleMergeService: SubtitleMergingServicing {
    private let aligner = SubtitleAligner()
    private let pageSize = 50

    func merge(
        source: SubtitleDocument,
        target: SubtitleDocument,
        outputFormat: SubtitleFormatKind,
        vadResult: VADArbitrationResult? = nil,
        alignmentReport: AlignmentReport? = nil,
        onSegment: ((MergeSegment) -> Void)? = nil,
        onPage: (([BilingualCue], Int, Int?) -> Void)? = nil
    ) -> MergedSubtitleDocument {
        // Use the pre-computed report when provided (target is already normalized).
        // Otherwise normalize here and use the normalized target for accurate timings.
        let report: AlignmentReport
        let effectiveTarget: SubtitleDocument
        if let alignmentReport {
            report = alignmentReport
            effectiveTarget = target
        } else {
            let norm = aligner.normalizeSecondaryForTimelineMerge(
                source: source, target: target, vadResult: vadResult
            )
            report = norm.normalization.report
            effectiveTarget = norm.normalizedTarget
        }

        let sourceCues = source.cues
        let targetCues = effectiveTarget.cues
        let sourceByID = Dictionary(uniqueKeysWithValues: sourceCues.map { ($0.id, $0) })
        let targetByID = Dictionary(uniqueKeysWithValues: targetCues.map { ($0.id, $0) })
        let segments = buildSegments(report: report, sourceByID: sourceByID, vadResult: vadResult)

        var allCues: [BilingualCue] = []
        var nextID = 1
        var emittedPages = 0

        for segment in segments {
            onSegment?(MergeSegment(
                startMilliseconds: segment.startMilliseconds,
                endMilliseconds: segment.endMilliseconds,
                isSourceMaster: segment.isSourceMaster
            ))

            let segCues = buildSegmentTimeline(segment: segment, sourceByID: sourceByID,
                                               targetByID: targetByID, startID: nextID)
            nextID += segCues.count
            allCues.append(contentsOf: segCues)

            // Emit only complete pages while iterating segments
            while allCues.count >= (emittedPages + 1) * pageSize {
                let start = emittedPages * pageSize
                onPage?(Array(allCues[start..<start + pageSize]), emittedPages + 1, nil)
                emittedPages += 1
            }
        }

        // Emit remaining cues as the final page (streaming preview — orphans added below)
        let remainingStart = emittedPages * pageSize
        if remainingStart < allCues.count {
            onPage?(Array(allCues[remainingStart...]), emittedPages + 1, emittedPages + 1)
        }

        // Collect secondary cues that were never matched (orphans)
        let matchedTargetIDs = Set(report.matches.compactMap(\.targetCueID))
        let orphanedTargetCues = targetCues.filter { !matchedTargetIDs.contains($0.id) }

        let matchedRanges = allCues.map { ($0.startMilliseconds, $0.endMilliseconds) }

        var orphanBilingualCues: [BilingualCue] = []
        for orphan in orphanedTargetCues {
            let text = orphan.plainText.normalizedSubtitleText
            guard !text.isEmpty else { continue }
            let overlaps = matchedRanges.contains {
                $0.0 < orphan.endMilliseconds && $0.1 > orphan.startMilliseconds
            }
            if overlaps { continue }
            orphanBilingualCues.append(BilingualCue(
                id: 0,
                startMilliseconds: orphan.startMilliseconds,
                endMilliseconds: orphan.endMilliseconds,
                sourceText: "",
                targetText: text,
                alignmentConfidence: 0.0,
                alignmentStatus: .unmatched
            ))
        }

        if !orphanBilingualCues.isEmpty {
            allCues = (allCues + orphanBilingualCues)
                .sorted { $0.startMilliseconds < $1.startMilliseconds }
        }
        allCues = allCues.enumerated().map { i, cue in
            BilingualCue(
                id: i + 1,
                startMilliseconds: cue.startMilliseconds,
                endMilliseconds: cue.endMilliseconds,
                sourceText: cue.sourceText,
                targetText: cue.targetText,
                alignmentConfidence: cue.alignmentConfidence,
                alignmentStatus: cue.alignmentStatus
            )
        }

        let orphanedSourceIDs = Set(
            report.matches.filter { $0.targetCueID == nil }.map(\.sourceCueID)
        )
        let orphanedTargetIDs = Set(orphanedTargetCues.map(\.id))
        let finalReport = AlignmentReport(
            matches: report.matches,
            matchedCueRatio: report.matchedCueRatio,
            lowConfidenceCueRatio: report.lowConfidenceCueRatio,
            unmatchedCueRatio: report.unmatchedCueRatio,
            medianStartDeltaMilliseconds: report.medianStartDeltaMilliseconds,
            monotonicityViolations: report.monotonicityViolations,
            averageConfidence: report.averageConfidence,
            detectedTimingOffsetMilliseconds: report.detectedTimingOffsetMilliseconds,
            orphanedSourceCueIDs: orphanedSourceIDs,
            orphanedTargetCueIDs: orphanedTargetIDs
        )

        return MergedSubtitleDocument(
            sourceLanguage: source.language,
            targetLanguage: target.language,
            outputFormat: outputFormat,
            cues: allCues,
            alignmentReport: finalReport
        )
    }

    // MARK: - Segment Building

    private func buildSegments(
        report: AlignmentReport,
        sourceByID: [Int: SubtitleCue],
        vadResult: VADArbitrationResult?
    ) -> [AlignmentSegment] {
        var segments: [AlignmentSegment] = []
        var currentMatches: [CueAlignmentMatch] = []
        var currentIsSourceMaster: Bool?
        var currentStart: Int?
        var currentEnd: Int?

        func flush() {
            guard !currentMatches.isEmpty, let start = currentStart, let end = currentEnd else { return }
            segments.append(AlignmentSegment(
                matches: currentMatches, isSourceMaster: currentIsSourceMaster ?? true,
                startMilliseconds: start, endMilliseconds: end
            ))
            currentMatches = []; currentIsSourceMaster = nil; currentStart = nil; currentEnd = nil
        }

        for match in report.matches {
            let isSourceMaster = vadResult.map {
                $0.masterSide(for: match.sourceCueID, targetCueID: match.targetCueID) == .source
            } ?? true

            if let existing = currentIsSourceMaster, isSourceMaster != existing { flush() }
            currentIsSourceMaster = isSourceMaster
            currentMatches.append(match)

            if let src = sourceByID[match.sourceCueID] {
                currentStart = currentStart.map { min($0, src.startMilliseconds) } ?? src.startMilliseconds
                currentEnd = currentEnd.map { max($0, src.endMilliseconds) } ?? src.endMilliseconds
            }
        }
        flush()

        return segments
    }

    // MARK: - Per-Segment Timeline

    private func buildSegmentTimeline(
        segment: AlignmentSegment,
        sourceByID: [Int: SubtitleCue],
        targetByID: [Int: SubtitleCue],
        startID: Int
    ) -> [BilingualCue] {
        let isSourceMaster = segment.isSourceMaster
        let masterCues: [SubtitleCue]
        let secondaryCues: [SubtitleCue]

        if isSourceMaster {
            masterCues = segment.matches.compactMap { sourceByID[$0.sourceCueID] }
            secondaryCues = segment.matches.compactMap { $0.targetCueID.flatMap { targetByID[$0] } }
        } else {
            masterCues = segment.matches.compactMap { $0.targetCueID.flatMap { targetByID[$0] } }
            secondaryCues = segment.matches.compactMap { sourceByID[$0.sourceCueID] }
        }

        return masterCues.enumerated().map { offset, masterCue in
            let secondaryText = secondaryCues
                .filter { $0.startMilliseconds < masterCue.endMilliseconds
                    && $0.endMilliseconds > masterCue.startMilliseconds }
                .map { $0.plainText.normalizedSubtitleText }
                .removingAdjacentDuplicates()
                .joined(separator: " ")

            let srcText = isSourceMaster ? masterCue.plainText.normalizedSubtitleText : secondaryText
            let tgtText = isSourceMaster ? secondaryText : masterCue.plainText.normalizedSubtitleText
            let hasBoth = !srcText.isEmpty && !tgtText.isEmpty

            return BilingualCue(
                id: startID + offset,
                startMilliseconds: masterCue.startMilliseconds,
                endMilliseconds: masterCue.endMilliseconds,
                sourceText: srcText,
                targetText: tgtText,
                alignmentConfidence: hasBoth ? 1.0 : 0.0,
                alignmentStatus: hasBoth ? .matched : .unmatched
            )
        }
    }
}

// MARK: - Supporting Types

private struct AlignmentSegment {
    let matches: [CueAlignmentMatch]
    let isSourceMaster: Bool
    let startMilliseconds: Int
    let endMilliseconds: Int
}

private extension Array where Element == String {
    func removingAdjacentDuplicates() -> [String] {
        reduce(into: [String]()) { result, text in
            guard result.last != text else { return }
            result.append(text)
        }
    }
}

struct SubtitleExportService: SubtitleExportServicing {
    func export(_ merged: MergedSubtitleDocument, to destinationURL: URL) throws {
        let content: String
        switch merged.outputFormat {
        case .srt:
            content = renderSRT(merged)
        case .ass:
            content = renderASS(merged)
        case .vtt:
            content = renderVTT(merged)
        case .unknown:
            throw WorkflowError.unsupported("Unsupported export format.")
        }

        try content.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    private func renderSRT(_ merged: MergedSubtitleDocument) -> String {
        merged.cues.map { cue in
            [
                "\(cue.id)",
                "\(formatSRTTime(cue.startMilliseconds)) --> \(formatSRTTime(cue.endMilliseconds))",
                cue.combinedText
            ]
            .joined(separator: "\n")
        }
        .joined(separator: "\n\n")
        + "\n"
    }

    private func renderVTT(_ merged: MergedSubtitleDocument) -> String {
        let body = merged.cues.map { cue in
            [
                "\(formatVTTTime(cue.startMilliseconds)) --> \(formatVTTTime(cue.endMilliseconds))",
                cue.combinedText
            ]
            .joined(separator: "\n")
        }
        .joined(separator: "\n\n")

        return "WEBVTT\n\n" + body + "\n"
    }

    private func renderASS(_ merged: MergedSubtitleDocument) -> String {
        let header = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
        Style: Default,Helvetica Neue,30,&H00FFFFFF,&H0000FFFF,&H64000000,&H50000000,0,0,0,0,100,100,0,0,1,2,0,2,60,60,40,1

        [Events]
        Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
        """

        let events = merged.cues.map { cue in
            let text = cue.combinedText
                .replacingOccurrences(of: "\n", with: "\\N")
                .replacingOccurrences(of: ",", with: "，")

            return "Dialogue: 0,\(formatASSTime(cue.startMilliseconds)),\(formatASSTime(cue.endMilliseconds)),Default,,0,0,0,,\(text)"
        }
        .joined(separator: "\n")

        return header + "\n" + events + "\n"
    }

    private func formatSRTTime(_ milliseconds: Int) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let millis = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    private func formatVTTTime(_ milliseconds: Int) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let millis = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    }

    private func formatASSTime(_ milliseconds: Int) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let centiseconds = (milliseconds % 1_000) / 10
        return String(format: "%01d:%02d:%02d.%02d", hours, minutes, seconds, centiseconds)
    }
}
