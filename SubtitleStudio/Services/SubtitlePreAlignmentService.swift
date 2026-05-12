import Foundation

struct SubtitlePreAlignmentService: SubtitlePreAlignmentServicing {
    private let aligner: SubtitleAligner
    private let offsetThresholdMs: Int = 200
    private let onsetSearchWindowMs: Int = 2_000

    init(aligner: SubtitleAligner = SubtitleAligner()) {
        self.aligner = aligner
    }

    func preAlign(
        native: SubtitleDocument,
        reference: SubtitleDocument,
        vadResult: VADArbitrationResult?
    ) async throws -> PreAlignmentOutcome {
        let (correctedNative, correctedReference, appliedOffsetMs, usedVAD) =
            applyVADOffsetCorrection(native: native, reference: reference, vadResult: vadResult)

        let iteration = aligner.alignIteratively(
            source: correctedNative,
            target: correctedReference,
            vadResult: vadResult
        )

        var confidenceScores: [Int: Double] = [:]
        for match in iteration.report.matches {
            confidenceScores[match.sourceCueID] = match.confidence
        }

        return PreAlignmentOutcome(
            alignedOriginal: correctedNative,
            alignedReference: correctedReference,
            confidenceScores: confidenceScores,
            appliedOffsetMs: appliedOffsetMs,
            usedVAD: usedVAD
        )
    }

    private func applyVADOffsetCorrection(
        native: SubtitleDocument,
        reference: SubtitleDocument,
        vadResult: VADArbitrationResult?
    ) -> (SubtitleDocument, SubtitleDocument, Int, Bool) {
        guard let vadResult, !vadResult.speechSegments.isEmpty, !native.cues.isEmpty else {
            return (native, reference, 0, false)
        }

        let onsets = vadResult.speechSegments
            .map(\.startMilliseconds)
            .sorted()

        var deltas: [Int] = []
        deltas.reserveCapacity(native.cues.count)
        for cue in native.cues {
            if let onset = nearestOnset(to: cue.startMilliseconds, in: onsets, windowMs: onsetSearchWindowMs) {
                deltas.append(cue.startMilliseconds - onset)
            }
        }

        guard !deltas.isEmpty else {
            return (native, reference, 0, true)
        }

        let sorted = deltas.sorted()
        let median: Int
        if sorted.count.isMultiple(of: 2) {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }

        guard abs(median) > offsetThresholdMs else {
            return (native, reference, 0, true)
        }

        let shift = -median
        return (
            shiftCues(in: native, by: shift),
            shiftCues(in: reference, by: shift),
            shift,
            true
        )
    }

    private func nearestOnset(to cueStartMs: Int, in onsets: [Int], windowMs: Int) -> Int? {
        guard !onsets.isEmpty else { return nil }
        var lo = 0
        var hi = onsets.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if onsets[mid] < cueStartMs {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let candidates = [lo - 1, lo].compactMap { idx -> Int? in
            guard idx >= 0 && idx < onsets.count else { return nil }
            return onsets[idx]
        }
        let best = candidates.min(by: { abs($0 - cueStartMs) < abs($1 - cueStartMs) })
        guard let onset = best, abs(onset - cueStartMs) <= windowMs else { return nil }
        return onset
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
            language: document.language,
            format: document.format,
            origin: document.origin,
            sourceLabel: document.sourceLabel,
            cues: shifted
        )
    }
}
