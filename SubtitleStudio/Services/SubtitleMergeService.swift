import Foundation

struct SubtitleMergeService: SubtitleMergingServicing {
    private let aligner = SubtitleAligner()
    private let boundarySnapToleranceMilliseconds = 250

    func merge(
        source: SubtitleDocument,
        target: SubtitleDocument,
        outputFormat: SubtitleFormatKind
    ) -> MergedSubtitleDocument {
        let timelineNormalization = aligner.normalizeSecondaryForTimelineMerge(source: source, target: target)
        let alignmentReport = timelineNormalization.normalization.report
        let sourceCues = normalizedTimelineCues(from: source.cues)
        let sourceBoundaries = Set(sourceCues.flatMap { [$0.startMilliseconds, $0.endMilliseconds] })
        let targetCues = normalizedTimelineCues(from: timelineNormalization.normalizedTarget.cues)
            .compactMap { cue -> TimelineCue? in
                let start = snappedBoundary(for: cue.startMilliseconds, sourceBoundaries: sourceBoundaries)
                let end = snappedBoundary(for: cue.endMilliseconds, sourceBoundaries: sourceBoundaries)
                guard end > start else { return nil }
                return TimelineCue(
                    startMilliseconds: start,
                    endMilliseconds: end,
                    text: cue.text
                )
            }
        let cues = buildTimelineCues(sourceCues: sourceCues, targetCues: targetCues)

        return MergedSubtitleDocument(
            sourceLanguage: source.language,
            targetLanguage: target.language,
            outputFormat: outputFormat,
            cues: cues,
            alignmentReport: alignmentReport
        )
    }

    private func normalizedTimelineCues(from cues: [SubtitleCue]) -> [TimelineCue] {
        cues.compactMap { cue in
            let text = cue.plainText.normalizedSubtitleText
            guard cue.endMilliseconds > cue.startMilliseconds, !text.isEmpty else { return nil }
            return TimelineCue(
                startMilliseconds: cue.startMilliseconds,
                endMilliseconds: cue.endMilliseconds,
                text: text
            )
        }
    }

    private func snappedBoundary(for time: Int, sourceBoundaries: Set<Int>) -> Int {
        guard let nearest = sourceBoundaries.min(by: { abs($0 - time) < abs($1 - time) }),
              abs(nearest - time) <= boundarySnapToleranceMilliseconds else {
            return time
        }
        return nearest
    }

    private func buildTimelineCues(sourceCues: [TimelineCue], targetCues: [TimelineCue]) -> [BilingualCue] {
        let times = Set((sourceCues + targetCues).flatMap { [$0.startMilliseconds, $0.endMilliseconds] }).sorted()
        guard times.count >= 2 else { return [] }

        let slices = zip(times.dropLast(), times.dropFirst()).compactMap { start, end -> TimelineSlice? in
            guard end > start else { return nil }
            let sourceText = joinedTextsCovering(sourceCues, start: start, end: end)
            let targetText = joinedTextsCovering(targetCues, start: start, end: end)
            guard !sourceText.isEmpty || !targetText.isEmpty else { return nil }
            return TimelineSlice(
                startMilliseconds: start,
                endMilliseconds: end,
                sourceText: sourceText,
                targetText: targetText
            )
        }

        let mergedSlices = mergeAdjacentEquivalentSlices(slices)
        return mergedSlices.enumerated().map { index, slice in
            let hasBothTexts = !slice.sourceText.isEmpty && !slice.targetText.isEmpty
            return BilingualCue(
                id: index + 1,
                startMilliseconds: slice.startMilliseconds,
                endMilliseconds: slice.endMilliseconds,
                sourceText: slice.sourceText,
                targetText: slice.targetText,
                alignmentConfidence: hasBothTexts ? 1 : 0,
                alignmentStatus: hasBothTexts ? .matched : .unmatched
            )
        }
    }

    private func joinedTextsCovering(_ cues: [TimelineCue], start: Int, end: Int) -> String {
        cues
            .filter { $0.startMilliseconds < end && $0.endMilliseconds > start }
            .map(\.text)
            .removingAdjacentDuplicates()
            .joined(separator: " ")
    }

    private func mergeAdjacentEquivalentSlices(_ slices: [TimelineSlice]) -> [TimelineSlice] {
        slices.reduce(into: [TimelineSlice]()) { merged, slice in
            guard let previous = merged.last,
                  previous.endMilliseconds == slice.startMilliseconds,
                  previous.sourceText == slice.sourceText,
                  previous.targetText == slice.targetText else {
                merged.append(slice)
                return
            }

            merged[merged.count - 1] = TimelineSlice(
                startMilliseconds: previous.startMilliseconds,
                endMilliseconds: slice.endMilliseconds,
                sourceText: previous.sourceText,
                targetText: previous.targetText
            )
        }
    }
}

private struct TimelineCue {
    let startMilliseconds: Int
    let endMilliseconds: Int
    let text: String
}

private struct TimelineSlice {
    let startMilliseconds: Int
    let endMilliseconds: Int
    let sourceText: String
    let targetText: String
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
