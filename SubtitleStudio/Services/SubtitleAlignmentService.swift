import Foundation

struct TimelineMergeNormalizationResult: Equatable, Sendable {
    let normalization: AlignmentNormalizationResult
    let normalizedTarget: SubtitleDocument
}

struct SubtitleAligner {
    private enum Operation {
        case match
        case skipSource
        case skipTarget
    }

    private let strongMatchThreshold = 0.58
    private let lowConfidenceThreshold = 0.30
    private let skipSourcePenalty = -0.28
    private let skipTargetPenalty = -0.18

    private let adPatterns: [String] = [
        "yts", "yify", "downloaded from", "official",
        "subscribe", "bit.ly", "www.", "http",
        "torrent", "ettv", "rarbg", "scenes"
    ]

    private let maxAdDurationMilliseconds: Int = 5_000
    private let maxAdTextLength: Int = 80

    func align(source: SubtitleDocument, target: SubtitleDocument, vadResult: VADArbitrationResult? = nil) -> AlignmentReport {
        guard !source.cues.isEmpty else { return .empty }
        guard !target.cues.isEmpty else {
            return report(for: source.cues.map {
                CueAlignmentMatch(
                    sourceCueID: $0.id,
                    targetCueID: nil,
                    confidence: 0,
                    status: .unmatched,
                    startDeltaMilliseconds: nil
                )
            })
        }

        let sourceCues = source.cues
        let targetCues = target.cues
        let sourceCount = sourceCues.count
        let targetCount = targetCues.count

        var scores = Array(
            repeating: Array(repeating: Double.leastNormalMagnitude, count: targetCount + 1),
            count: sourceCount + 1
        )
        var operations = Array(
            repeating: Array(repeating: Operation.skipSource, count: targetCount + 1),
            count: sourceCount + 1
        )

        scores[sourceCount][targetCount] = 0

        if sourceCount > 0 {
            for sourceIndex in stride(from: sourceCount - 1, through: 0, by: -1) {
                scores[sourceIndex][targetCount] = skipSourcePenalty + scores[sourceIndex + 1][targetCount]
                operations[sourceIndex][targetCount] = .skipSource
            }
        }

        if targetCount > 0 {
            for targetIndex in stride(from: targetCount - 1, through: 0, by: -1) {
                scores[sourceCount][targetIndex] = skipTargetPenalty + scores[sourceCount][targetIndex + 1]
                operations[sourceCount][targetIndex] = .skipTarget
            }
        }

        if sourceCount > 0 && targetCount > 0 {
            for sourceIndex in stride(from: sourceCount - 1, through: 0, by: -1) {
                for targetIndex in stride(from: targetCount - 1, through: 0, by: -1) {
                    let sourceCue = sourceCues[sourceIndex]
                    let targetCue = targetCues[targetIndex]
                    let overlap = max(0, min(sourceCue.endMilliseconds, targetCue.endMilliseconds) - max(sourceCue.startMilliseconds, targetCue.startMilliseconds))

                    // Hard constraint: zero-overlap pairs are never valid matches.
                    // Prevents temporal inversions (e.g., matching English cue A with Polish cue B
                    // where B starts after A ends, forcing subsequent English cues to match
                    // with earlier Polish cues and cascading blanks).
                    let isNonOverlappingMatch = overlap == 0

                    let pairScore = pairConfidence(source: sourceCue, target: targetCue, vadResult: vadResult)
                    let matchScore = isNonOverlappingMatch ? Double.leastNormalMagnitude : pairScore + scores[sourceIndex + 1][targetIndex + 1]
                    let skipSourceScore = skipSourcePenalty + scores[sourceIndex + 1][targetIndex]
                    let skipTargetScore = skipTargetPenalty + scores[sourceIndex][targetIndex + 1]

                    if matchScore >= skipSourceScore && matchScore >= skipTargetScore {
                        scores[sourceIndex][targetIndex] = matchScore
                        operations[sourceIndex][targetIndex] = .match
                    } else if skipSourceScore >= skipTargetScore {
                        scores[sourceIndex][targetIndex] = skipSourceScore
                        operations[sourceIndex][targetIndex] = .skipSource
                    } else {
                        scores[sourceIndex][targetIndex] = skipTargetScore
                        operations[sourceIndex][targetIndex] = .skipTarget
                    }
                }
            }
        }

        var matches: [CueAlignmentMatch] = []
        var sourceIndex = 0
        var targetIndex = 0

        while sourceIndex < sourceCount || targetIndex < targetCount {
            if sourceIndex == sourceCount {
                targetIndex += 1
                continue
            }

            if targetIndex == targetCount {
                matches.append(
                    CueAlignmentMatch(
                        sourceCueID: sourceCues[sourceIndex].id,
                        targetCueID: nil,
                        confidence: 0,
                        status: .unmatched,
                        startDeltaMilliseconds: nil
                    )
                )
                sourceIndex += 1
                continue
            }

            switch operations[sourceIndex][targetIndex] {
            case .match:
                let sourceCue = sourceCues[sourceIndex]
                let targetCue = targetCues[targetIndex]
                let confidence = pairConfidence(source: sourceCue, target: targetCue)
                let status: CueAlignmentStatus
                if confidence >= strongMatchThreshold {
                    status = .matched
                } else if confidence >= lowConfidenceThreshold {
                    status = .lowConfidence
                } else {
                    status = .unmatched
                }

                matches.append(
                    CueAlignmentMatch(
                        sourceCueID: sourceCue.id,
                        targetCueID: status == .unmatched ? nil : targetCue.id,
                        confidence: confidence,
                        status: status,
                        startDeltaMilliseconds: abs(sourceCue.startMilliseconds - targetCue.startMilliseconds)
                    )
                )
                sourceIndex += 1
                targetIndex += 1
            case .skipSource:
                matches.append(
                    CueAlignmentMatch(
                        sourceCueID: sourceCues[sourceIndex].id,
                        targetCueID: nil,
                        confidence: 0,
                        status: .unmatched,
                        startDeltaMilliseconds: nil
                    )
                )
                sourceIndex += 1
            case .skipTarget:
                targetIndex += 1
            }
        }

        return report(for: matches)
    }

    func pairedTargetCues(
        source: SubtitleDocument,
        target: SubtitleDocument
    ) -> [(cue: SubtitleCue, match: CueAlignmentMatch)] {
        let report = align(source: source, target: target)
        let targetByID = Dictionary(uniqueKeysWithValues: target.cues.map { ($0.id, $0) })
        return report.matches.compactMap { match in
            guard let targetCueID = match.targetCueID,
                  let cue = targetByID[targetCueID]
            else { return nil }
            return (cue, match)
        }
    }

    func normalizeSecondaryToSource(
        source: SubtitleDocument,
        target: SubtitleDocument
    ) -> AlignmentNormalizationResult {
        normalizeSecondaryForTimelineMerge(source: source, target: target).normalization
    }

    func normalizeSecondaryForTimelineMerge(
        source: SubtitleDocument,
        target: SubtitleDocument,
        vadResult: VADArbitrationResult? = nil
    ) -> TimelineMergeNormalizationResult {
        let iterationResult = alignIteratively(source: source, target: target, vadResult: vadResult)
        let filteredTarget = SubtitleDocument(
            language: target.language,
            format: target.format,
            origin: target.origin,
            sourceLabel: target.sourceLabel,
            cues: target.cues.filter { !iterationResult.detectedAds.contains($0.id) }
        )
        let normalizedTarget = normalizedTargetDocument(
            from: filteredTarget,
            appliedOffset: iterationResult.appliedOffset
        )

        let primaryMatchedTextsBySourceCueID = iterationResult.report.matches.reduce(into: [Int: String]()) { partialResult, match in
            guard match.status == .matched,
                  let targetCueID = match.targetCueID,
                  let text = normalizedTarget.cues.first(where: { $0.id == targetCueID })?.plainText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            partialResult[match.sourceCueID] = text
        }
        let referenceSpansBySourceCueID = buildReferenceSpans(
            source: source,
            normalizedTarget: normalizedTarget,
            report: iterationResult.report
        )

        let normalization = AlignmentNormalizationResult(
            report: iterationResult.report,
            iterations: iterationResult.iterations,
            detectedAds: iterationResult.detectedAds,
            appliedOffset: iterationResult.appliedOffset,
            primaryMatchedTextsBySourceCueID: primaryMatchedTextsBySourceCueID,
            referenceSpansBySourceCueID: referenceSpansBySourceCueID
        )

        return TimelineMergeNormalizationResult(
            normalization: normalization,
            normalizedTarget: normalizedTarget
        )
    }

    private func report(for matches: [CueAlignmentMatch]) -> AlignmentReport {
        let count = Double(max(matches.count, 1))
        let matched = matches.filter { $0.status == .matched }
        let lowConfidence = matches.filter { $0.status == .lowConfidence }
        let unmatched = matches.filter { $0.status == .unmatched }
        let deltas = matches.compactMap(\.startDeltaMilliseconds).sorted()
        let medianDelta: Double
        if deltas.isEmpty {
            medianDelta = 0
        } else {
            let middle = deltas.count / 2
            if deltas.count.isMultiple(of: 2) {
                medianDelta = Double(deltas[middle - 1] + deltas[middle]) / 2
            } else {
                medianDelta = Double(deltas[middle])
            }
        }

        return AlignmentReport(
            matches: matches,
            matchedCueRatio: Double(matched.count) / count,
            lowConfidenceCueRatio: Double(lowConfidence.count) / count,
            unmatchedCueRatio: Double(unmatched.count) / count,
            medianStartDeltaMilliseconds: medianDelta,
            monotonicityViolations: 0,
            averageConfidence: matches.isEmpty ? 0 : matches.map(\.confidence).reduce(0, +) / count,
            detectedTimingOffsetMilliseconds: nil,
            orphanedSourceCueIDs: [],
            orphanedTargetCueIDs: []
        )
    }

    private func pairConfidence(source: SubtitleCue, target: SubtitleCue, vadResult: VADArbitrationResult? = nil) -> Double {
        let overlap = max(0, min(source.endMilliseconds, target.endMilliseconds) - max(source.startMilliseconds, target.startMilliseconds))
        let sourceDuration = max(source.durationMilliseconds, 1)
        let targetDuration = max(target.durationMilliseconds, 1)
        let maxDuration = max(sourceDuration, targetDuration)

        // A secondary subtitle cue can legitimately be longer than the source cue
        // after segmentation differences. Treat full containment as a strong signal
        // instead of scoring only against the longer duration.
        let overlapRatio =
            ((Double(overlap) / Double(sourceDuration)) + (Double(overlap) / Double(targetDuration))) / 2
        let startDelta = abs(source.startMilliseconds - target.startMilliseconds)
        let endDelta = abs(source.endMilliseconds - target.endMilliseconds)
        let durationSimilarity = Double(min(sourceDuration, targetDuration)) / Double(maxDuration)

        let startCloseness = max(0, 1 - Double(startDelta) / 2_500)
        let endCloseness = max(0, 1 - Double(endDelta) / 2_500)
        let textBonus = target.plainText.normalizedSubtitleText.isEmpty ? -0.2 : 0.05
        let noOverlapPenalty = overlap == 0 && startDelta > 1_200 ? 0.22 : 0

        let vadTerm = vadAgreementTerm(source: source, target: target, vadResult: vadResult)
        let rawScore =
            (overlapRatio * (vadResult != nil ? 0.40 : 0.52)) +
            (startCloseness * 0.15) +
            (endCloseness * 0.12) +
            (durationSimilarity * 0.11) +
            vadTerm +
            textBonus -
            noOverlapPenalty

        return min(max(rawScore, 0), 1)
    }

    private func vadAgreementTerm(source: SubtitleCue, target: SubtitleCue, vadResult: VADArbitrationResult?) -> Double {
        guard let vadResult else { return 0 }
        let s = vadResult.sourceScores[source.id]?.speechOverlapRatio ?? 0
        let t = vadResult.targetScores[target.id]?.speechOverlapRatio ?? 0
        return (1.0 - abs(s - t)) * 0.22
    }

    func detectAdCues(in document: SubtitleDocument, otherCues _: [SubtitleCue]) -> Set<Int> {
        var detected: Set<Int> = []

        for cue in document.cues {
            let isShort = cue.durationMilliseconds <= maxAdDurationMilliseconds
            let isBrief = cue.plainText.count < maxAdTextLength
            let hasAdPattern = adPatterns.contains { pattern in
                cue.plainText.lowercased().contains(pattern)
            }

            if isShort && isBrief && hasAdPattern {
                detected.insert(cue.id)
            }
        }
        return detected
    }

    func calculateOffset(source sourceCues: [SubtitleCue], target targetCues: [SubtitleCue], adCues: Set<Int> = []) -> OffsetCorrection? {
        let filteredSource = sourceCues.filter { !adCues.contains($0.id) }
        let filteredTarget = targetCues.filter { !adCues.contains($0.id) }

        // Use existing aligner to get high-confidence aligned pairs
        let sourceDoc = SubtitleDocument(language: .english, format: .srt, origin: .localFile, sourceLabel: "", cues: filteredSource)
        let targetDoc = SubtitleDocument(language: .polish, format: .srt, origin: .localFile, sourceLabel: "", cues: filteredTarget)
        let pairs = pairedTargetCues(source: sourceDoc, target: targetDoc)

        var deltas: [Int] = []
        let sourceByID = Dictionary(uniqueKeysWithValues: filteredSource.map { ($0.id, $0) })
        for (targetCue, match) in pairs where match.confidence >= lowConfidenceThreshold {
            if let sourceCue = sourceByID[match.sourceCueID] {
                deltas.append(targetCue.startMilliseconds - sourceCue.startMilliseconds)
            }
        }

        guard !deltas.isEmpty else { return nil }
        let sortedDeltas = deltas.sorted()
        let median = sortedDeltas.count.isMultiple(of: 2)
            ? (sortedDeltas[sortedDeltas.count / 2 - 1] + sortedDeltas[sortedDeltas.count / 2]) / 2
            : sortedDeltas[sortedDeltas.count / 2]

        if abs(median) > 200 {
            return OffsetCorrection(milliseconds: median, appliedTo: .source)
        }
        return nil
    }

    func alignIteratively(source: SubtitleDocument, target: SubtitleDocument, vadResult: VADArbitrationResult? = nil) -> AlignmentIterationResult {
        let report1 = align(source: source, target: target, vadResult: vadResult)
        let lowConfidenceSourceIDs = Set(
            report1.matches
                .filter { $0.status == .lowConfidence || $0.status == .unmatched }
                .map(\.sourceCueID)
        )
        let matchedTargetIDs = Set(report1.matches.compactMap(\.targetCueID))
        let adsFromSource = detectAdCues(in: source, otherCues: target.cues)
            .intersection(lowConfidenceSourceIDs)
        let adsFromTarget = detectAdCues(in: target, otherCues: source.cues)
            .subtracting(matchedTargetIDs)
        let detectedAds = adsFromSource.union(adsFromTarget)

        let filteredSourceCues = source.cues.filter { !detectedAds.contains($0.id) }
        let filteredTargetCues = target.cues.filter { !detectedAds.contains($0.id) }
        let filteredSource = SubtitleDocument(
            language: source.language,
            format: source.format,
            origin: source.origin,
            sourceLabel: source.sourceLabel,
            cues: filteredSourceCues
        )
        let filteredTarget = SubtitleDocument(
            language: target.language,
            format: target.format,
            origin: target.origin,
            sourceLabel: target.sourceLabel,
            cues: filteredTargetCues
        )

        let needsFilteredPass = !detectedAds.isEmpty
        let filteredReport = needsFilteredPass
            ? align(source: filteredSource, target: filteredTarget, vadResult: vadResult)
            : report1
        let baseIterations = needsFilteredPass ? 2 : 1

        if let offset = calculateOffset(source: filteredSourceCues, target: filteredTargetCues) {
            let shiftedSource = shiftCues(in: filteredSource, by: offset.milliseconds)
            let finalReport = align(source: shiftedSource, target: filteredTarget)
            return AlignmentIterationResult(
                report: finalReport,
                iterations: baseIterations + 1,
                detectedAds: detectedAds,
                appliedOffset: offset
            )
        }

        return AlignmentIterationResult(
            report: filteredReport,
            iterations: baseIterations,
            detectedAds: detectedAds,
            appliedOffset: nil
        )
    }

    private func shiftCues(in document: SubtitleDocument, by milliseconds: Int) -> SubtitleDocument {
        let shifted = document.cues.map { cue in
            SubtitleCue(
                id: cue.id,
                startMilliseconds: cue.startMilliseconds + milliseconds,
                endMilliseconds: cue.endMilliseconds + milliseconds,
                rawText: cue.rawText,
                plainText: cue.plainText
            )
        }
        return SubtitleDocument(
            language: document.language, format: document.format, origin: document.origin,
            sourceLabel: document.sourceLabel, cues: shifted
        )
    }

    private func normalizedTargetDocument(
        from target: SubtitleDocument,
        appliedOffset: OffsetCorrection?
    ) -> SubtitleDocument {
        guard let appliedOffset else { return target }
        let shiftMilliseconds: Int
        switch appliedOffset.appliedTo {
        case .source:
            shiftMilliseconds = -appliedOffset.milliseconds
        case .target:
            shiftMilliseconds = appliedOffset.milliseconds
        }
        return shiftCues(in: target, by: shiftMilliseconds)
    }

    private func buildReferenceSpans(
        source: SubtitleDocument,
        normalizedTarget: SubtitleDocument,
        report: AlignmentReport
    ) -> [Int: NormalizedReferenceSpan] {
        let matchesBySourceID = Dictionary(uniqueKeysWithValues: report.matches.map { ($0.sourceCueID, $0) })
        let targetIndexByID = Dictionary(uniqueKeysWithValues: normalizedTarget.cues.enumerated().map { ($0.element.id, $0.offset) })

        return source.cues.reduce(into: [Int: NormalizedReferenceSpan]()) { partialResult, sourceCue in
            let primaryMatch = matchesBySourceID[sourceCue.id]
            let selectedTargets = selectReferenceSpanCues(
                for: sourceCue,
                normalizedTarget: normalizedTarget.cues,
                primaryTargetIndex: primaryMatch?.targetCueID.flatMap { targetIndexByID[$0] }
            )
            guard !selectedTargets.isEmpty else {
                return
            }

            let spanText = selectedTargets
                .map { $0.plainText.normalizedSubtitleText }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spanText.isEmpty else {
                return
            }

            let sourceDuration = max(sourceCue.durationMilliseconds, 1)
            let overlapCoverage = min(
                1,
                Double(totalOverlap(for: sourceCue, targets: selectedTargets)) / Double(sourceDuration)
            )
            let cueScores = selectedTargets.map { pairConfidence(source: sourceCue, target: $0) }
            let averageScore = cueScores.isEmpty ? 0 : cueScores.reduce(0, +) / Double(cueScores.count)
            let maxScore = cueScores.max() ?? 0
            let spanConfidence = min(1, (overlapCoverage * 0.5) + (averageScore * 0.25) + (maxScore * 0.25))

            let span = NormalizedReferenceSpan(
                sourceCueID: sourceCue.id,
                text: spanText,
                referenceCueIDs: selectedTargets.map(\.id),
                isMergedSpan: selectedTargets.count > 1,
                confidence: spanConfidence,
                primaryStatus: primaryMatch?.status ?? .unmatched
            )
            guard span.isReliable else {
                return
            }

            partialResult[sourceCue.id] = span
        }
    }

    private func selectReferenceSpanCues(
        for sourceCue: SubtitleCue,
        normalizedTarget: [SubtitleCue],
        primaryTargetIndex: Int?
    ) -> [SubtitleCue] {
        guard !normalizedTarget.isEmpty else { return [] }

        let toleranceMilliseconds = 250
        let maxGapMilliseconds = 450
        let expandedStart = sourceCue.startMilliseconds - toleranceMilliseconds
        let expandedEnd = sourceCue.endMilliseconds + toleranceMilliseconds

        let overlappingIndices = normalizedTarget.enumerated().compactMap { index, cue -> Int? in
            let overlaps = cue.startMilliseconds < expandedEnd && cue.endMilliseconds > expandedStart
            return overlaps ? index : nil
        }

        if let primaryTargetIndex {
            let primaryCue = normalizedTarget[primaryTargetIndex]
            let primaryCoverage = min(
                1,
                Double(totalOverlap(for: sourceCue, targets: [primaryCue])) / Double(max(sourceCue.durationMilliseconds, 1))
            )
            if primaryCoverage >= 0.72 {
                return [primaryCue]
            }

            var selected = Set<Int>(overlappingIndices)
            selected.insert(primaryTargetIndex)

            if primaryTargetIndex > 0 {
                let leftCue = normalizedTarget[primaryTargetIndex - 1]
                let leftGap = max(0, primaryCue.startMilliseconds - leftCue.endMilliseconds)
                let overlapsExpandedWindow = leftCue.startMilliseconds < expandedEnd && leftCue.endMilliseconds > expandedStart
                if overlapsExpandedWindow && leftGap <= maxGapMilliseconds {
                    selected.insert(primaryTargetIndex - 1)
                }
            }

            if primaryTargetIndex + 1 < normalizedTarget.count {
                let primaryCue = normalizedTarget[primaryTargetIndex]
                let rightCue = normalizedTarget[primaryTargetIndex + 1]
                let rightGap = max(0, rightCue.startMilliseconds - primaryCue.endMilliseconds)
                let overlapsExpandedWindow = rightCue.startMilliseconds < expandedEnd && rightCue.endMilliseconds > expandedStart
                if overlapsExpandedWindow && rightGap <= maxGapMilliseconds {
                    selected.insert(primaryTargetIndex + 1)
                }
            }

            return selected.sorted().prefix(3).map { normalizedTarget[$0] }
        }

        let contiguous = overlappingIndices.sorted().prefix(2)
        return contiguous.map { normalizedTarget[$0] }
    }

    private func totalOverlap(for sourceCue: SubtitleCue, targets: [SubtitleCue]) -> Int {
        targets.reduce(0) { partialResult, targetCue in
            partialResult + max(
                0,
                min(sourceCue.endMilliseconds, targetCue.endMilliseconds) - max(sourceCue.startMilliseconds, targetCue.startMilliseconds)
            )
        }
    }
}
