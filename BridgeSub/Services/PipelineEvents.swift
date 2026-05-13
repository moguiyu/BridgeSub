import Foundation

// MARK: - Discovery Events

enum DiscoveryEvent {
    case scanning(path: String)
    case candidateFound(SubtitleCandidate)
    case discoveryComplete(candidates: [SubtitleCandidate])
}

// MARK: - Load Events

enum LoadEvent {
    case loadProgress(card: Int, fraction: Double)
    case documentReady(card: Int, document: SubtitleDocument)
}

// MARK: - Merge Events

struct MergeSegment: Equatable, Sendable {
    let startMilliseconds: Int
    let endMilliseconds: Int
    let isSourceMaster: Bool
}

enum MergeEvent {
    case alignmentComplete(report: AlignmentReport)
    case segmentBuilt(segment: MergeSegment)
    case pageReady(cues: [BilingualCue], page: Int, totalPages: Int?)
    case mergeComplete(document: MergedSubtitleDocument)
}

// MARK: - Quality Events

enum QualityEvent {
    case evaluationComplete(report: SubtitleQualityReport)
}

// MARK: - Pre-Alignment Events

enum PreAlignmentEvent: Sendable {
    case started
    case skipped(reason: String)
    case completed(outcome: PreAlignmentOutcome)
    case failed(reason: String)
}
