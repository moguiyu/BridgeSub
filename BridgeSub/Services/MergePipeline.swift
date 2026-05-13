import Foundation

actor MergePipeline {
    private let mergeService: any SubtitleMergingServicing
    private let qualityService: any SubtitleQualityScoringServicing
    private let aligner: SubtitleAligner

    init(
        mergeService: any SubtitleMergingServicing,
        qualityService: any SubtitleQualityScoringServicing
    ) {
        self.mergeService = mergeService
        self.qualityService = qualityService
        self.aligner = SubtitleAligner()
    }

    func run(
        source: SubtitleDocument,
        target: SubtitleDocument,
        vadResult: VADArbitrationResult?,
        outputFormat: SubtitleFormatKind,
        pageSize: Int = 50
    ) -> (mergeEvents: AsyncStream<MergeEvent>, qualityEvents: AsyncStream<QualityEvent>) {

        let (mergeStream, mergeContinuation) = AsyncStream<MergeEvent>.makeStream()
        let (qualityStream, qualityContinuation) = AsyncStream<QualityEvent>.makeStream()

        // Compute normalization here so both tasks can capture the result.
        // SubtitleAligner is a value type — safe to capture by copy.
        let normalization = aligner.normalizeSecondaryForTimelineMerge(
            source: source, target: target, vadResult: vadResult
        )
        let report = normalization.normalization.report

        Task.detached { [mergeService, normalization, report] in
            mergeContinuation.yield(.alignmentComplete(report: report))

            let document = mergeService.merge(
                source: source,
                target: normalization.normalizedTarget,
                outputFormat: outputFormat,
                vadResult: vadResult,
                alignmentReport: report,
                onSegment: { segment in
                    mergeContinuation.yield(.segmentBuilt(segment: segment))
                },
                onPage: { cues, page, totalPages in
                    mergeContinuation.yield(.pageReady(cues: cues, page: page, totalPages: totalPages))
                }
            )

            mergeContinuation.yield(.mergeComplete(document: document))
            mergeContinuation.finish()
        }

        Task.detached { [qualityService, normalization, report] in
            let qualityReport = qualityService.evaluate(
                source: source,
                candidate: normalization.normalizedTarget,
                targetLanguage: target.language,
                alignmentReport: report
            )
            qualityContinuation.yield(.evaluationComplete(report: qualityReport))
            qualityContinuation.finish()
        }

        return (mergeStream, qualityStream)
    }
}
