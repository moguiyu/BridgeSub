# Pipeline Restructure & VAD-Arbitrated Merge — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restructure subtitle pipeline around unified async streams with VAD-arbitrated segment-based merging, recursive subtitle discovery, and streaming page-by-page preview.

**Architecture:** New `MergePipeline` actor chains Discovery→Load→VAD→Merge→Quality stages as async streams. `SubtitleMergeService` rebuilt with segment-based VAD arbitration (single master per segment, single boundary set). `WorkflowViewModel` subscribes to pipeline streams instead of spawning ad-hoc Tasks. Discovery scans recursively from video path, streaming candidates with origin/kind badges.

**Tech Stack:** Swift 6, SwiftUI, async/await, AsyncStream, TaskGroup

---

### Task 1: Add `kind` and `relativePath` to `SubtitleCandidate`

**Files:**
- Modify: `SubtitleStudio/Domain/Models.swift:1301-1344`

**Step 1: Add `kind` field to SubtitleCandidate**

At `Models.swift:1314` (after `languageProfile`), add:

```swift
var kind: CueKind?
```

**Step 2: Add `relativePath` field to SubtitleCandidate**

After `kind`, add:

```swift
var relativePath: String?
```

**Step 3: Update init**

At line 1316, add parameters with defaults:
```swift
kind: CueKind? = nil,
relativePath: String? = nil,
```

And set them in the body:
```swift
self.kind = kind
self.relativePath = relativePath
```

**Step 4: Add `.unknown` to `CueKind`**

At `Models.swift:48` (after `.ad`), add:

```swift
case unknown
```

This is required before Task 8 — `classifyCandidateKind()` returns `.unknown` as a fallback.

**Step 5: Build**

```bash
xcodegen generate && xcodebuild -project SubtitleStudio.xcodeproj -scheme SubtitleStudio -destination 'platform=macOS' build
```

Expected: Build succeeds. New fields are unused so far.

---

### Task 2: Add Pipeline Event Types

**Files:**
- Create: `SubtitleStudio/Services/PipelineEvents.swift`

> `project.yml` uses `- path: SubtitleStudio` (recursive include) — new files are picked up automatically; no yml edit needed.

**Step 1: Create PipelineEvents.swift**

```swift
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
    let master: Int  // card index: 0 = source, 1 = target
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
```

**Step 2: Build**

```bash
xcodegen generate && xcodebuild -project SubtitleStudio.xcodeproj -scheme SubtitleStudio -destination 'platform=macOS' build
```

---

### Task 3: Create MergePipeline Actor

**Files:**
- Create: `SubtitleStudio/Services/MergePipeline.swift`

> `project.yml` edit not needed — see Task 2 note.

**Step 1: Create MergePipeline.swift**

```swift
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

        // Compute normalization before spawning tasks so both closures can capture it.
        // (Compute inside `run` on the actor — SubtitleAligner is a value type, safe to send.)
        let normalization = aligner.normalizeSecondaryForTimelineMerge(
            source: source, target: target, vadResult: vadResult
        )
        let report = normalization.normalization.report

        Task.detached { [mergeService, normalization, report] in
            mergeContinuation.yield(.alignmentComplete(report: report))

            // Phase B: Segment-based merge with streaming pages
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
```

**Step 2: Build**

---

### Task 4: Update SubtitleMergingServicing Protocol

**Files:**
- Modify: `SubtitleStudio/Services/ServiceProtocols.swift:28-35`

**Step 1: Add streaming merge method to protocol**

Replace the current `merge` signature with:

```swift
protocol SubtitleMergingServicing {
    func merge(
        source: SubtitleDocument,
        target: SubtitleDocument,
        outputFormat: SubtitleFormatKind,
        vadResult: VADArbitrationResult?,
        alignmentReport: AlignmentReport?,
        onSegment: ((MergeSegment) -> Void)?,
        onPage: (([BilingualCue], Int, Int?) -> Void)?
    ) -> MergedSubtitleDocument
}
```

**Step 2: Build**

Expected: Build fails — `SubtitleMergeService` and callers need updating. This is expected; fixed in Tasks 5 and 6.

---

### Task 5: Rebuild SubtitleMergeService with Segment-Based Merge

**Files:**
- Modify: `SubtitleStudio/Services/SubtitleMergeService.swift` (entire file)

**Step 1: Rewrite merge() with segment arbitration**

Replace the entire `SubtitleMergeService` struct. The new merge algorithm:

```swift
struct SubtitleMergeService: SubtitleMergingServicing {
    private let aligner = SubtitleAligner()

    func merge(
        source: SubtitleDocument,
        target: SubtitleDocument,
        outputFormat: SubtitleFormatKind,
        vadResult: VADArbitrationResult? = nil,
        alignmentReport: AlignmentReport? = nil,
        onSegment: ((MergeSegment) -> Void)? = nil,
        onPage: (([BilingualCue], Int, Int?) -> Void)? = nil
    ) -> MergedSubtitleDocument {

        // Use provided alignment report or compute one
        let report: AlignmentReport
        if let alignmentReport {
            report = alignmentReport
        } else {
            let norm = aligner.normalizeSecondaryForTimelineMerge(
                source: source, target: target, vadResult: vadResult
            )
            report = norm.normalization.report
        }

        let sourceCues = source.cues
        let targetCues = target.cues

        // Partition aligned matches into segments
        let segments = buildSegments(
            report: report,
            sourceCues: sourceCues,
            targetCues: targetCues,
            vadResult: vadResult
        )

        // Build timeline per segment, streaming pages
        var allCues: [BilingualCue] = []
        var pageNumber = 0

        for segment in segments {
            onSegment?(segment)

            let segmentCues = buildSegmentTimeline(
                segment: segment,
                sourceCues: sourceCues,
                targetCues: targetCues
            )

            allCues.append(contentsOf: segmentCues)

            // Emit pages as we go
            while allCues.count > pageNumber * 50 {
                let pageStart = pageNumber * 50
                let pageEnd = min(pageStart + 50, allCues.count)
                let page = Array(allCues[pageStart..<pageEnd])
                onPage?(page, pageNumber + 1, nil)
                pageNumber += 1
            }
        }

        // Final page
        if allCues.count > pageNumber * 50 || allCues.isEmpty {
            let pageStart = pageNumber * 50
            let pageEnd = allCues.count
            if pageEnd > pageStart {
                let page = Array(allCues[pageStart..<pageEnd])
                onPage?(page, pageNumber + 1, pageNumber + 1)
            }
        }

        return MergedSubtitleDocument(
            sourceLanguage: source.language,
            targetLanguage: target.language,
            outputFormat: outputFormat,
            cues: allCues,
            alignmentReport: report
        )
    }

    // MARK: - Segment Building

    private func buildSegments(
        report: AlignmentReport,
        sourceCues: [SubtitleCue],
        targetCues: [SubtitleCue],
        vadResult: VADArbitrationResult?
    ) -> [AlignmentSegment] {

        let sourceByID = Dictionary(uniqueKeysWithValues: sourceCues.map { ($0.id, $0) })
        let targetByID = Dictionary(uniqueKeysWithValues: targetCues.map { ($0.id, $0) })

        var segments: [AlignmentSegment] = []
        var currentMatches: [CueAlignmentMatch] = []
        var currentMaster: Int? = nil
        var currentStart: Int? = nil
        var currentEnd: Int? = nil

        func flushSegment() {
            guard !currentMatches.isEmpty, let start = currentStart, let end = currentEnd else { return }
            segments.append(AlignmentSegment(
                matches: currentMatches,
                master: currentMaster ?? 0,
                startMilliseconds: start,
                endMilliseconds: end
            ))
            currentMatches = []
            currentMaster = nil
            currentStart = nil
            currentEnd = nil
        }

        for match in report.matches {
            let master = determineMaster(match: match, vadResult: vadResult)

            if master != currentMaster && !currentMatches.isEmpty {
                flushSegment()
            }

            currentMaster = master
            currentMatches.append(match)

            if let src = sourceByID[match.sourceCueID] {
                let segStart = src.startMilliseconds
                let segEnd = src.endMilliseconds
                currentStart = currentStart.map { min($0, segStart) } ?? segStart
                currentEnd = currentEnd.map { max($0, segEnd) } ?? segEnd
            }
        }
        flushSegment()

        return segments
    }

    private func determineMaster(
        match: CueAlignmentMatch,
        vadResult: VADArbitrationResult?
    ) -> Int {
        guard let vadResult else { return 0 }
        // Reuse the existing helper — same 0.15 threshold + document-average tie-break.
        let side = vadResult.masterSide(for: match.sourceCueID, targetCueID: match.targetCueID)
        return side == .source ? 0 : 1
    }

    // MARK: - Per-Segment Timeline

    private func buildSegmentTimeline(
        segment: AlignmentSegment,
        sourceCues: [SubtitleCue],
        targetCues: [SubtitleCue]
    ) -> [BilingualCue] {
        let sourceByID = Dictionary(uniqueKeysWithValues: sourceCues.map { ($0.id, $0) })
        let targetByID = Dictionary(uniqueKeysWithValues: targetCues.map { ($0.id, $0) })

        let masterCues: [SubtitleCue]
        let secondaryCues: [SubtitleCue]
        let isSourceMaster: Bool

        if segment.master == 0 {
            masterCues = segment.matches.compactMap { sourceByID[$0.sourceCueID] }
            secondaryCues = segment.matches.compactMap { $0.targetCueID.flatMap { targetByID[$0] } }
            isSourceMaster = true
        } else {
            masterCues = segment.matches.compactMap { $0.targetCueID.flatMap { targetByID[$0] } }
            secondaryCues = segment.matches.compactMap { sourceByID[$0.sourceCueID] }
            isSourceMaster = false
        }

        var result: [BilingualCue] = []
        var nextID = 1

        for masterCue in masterCues {
            let secondaryText = secondaryCues
                .filter { $0.startMilliseconds < masterCue.endMilliseconds && $0.endMilliseconds > masterCue.startMilliseconds }
                .map { $0.plainText.normalizedSubtitleText }
                .removingAdjacentDuplicates()
                .joined(separator: " ")

            let srcText = isSourceMaster ? masterCue.plainText.normalizedSubtitleText : secondaryText
            let tgtText = isSourceMaster ? secondaryText : masterCue.plainText.normalizedSubtitleText

            let hasBoth = !srcText.isEmpty && !tgtText.isEmpty
            result.append(BilingualCue(
                id: nextID,
                startMilliseconds: masterCue.startMilliseconds,
                endMilliseconds: masterCue.endMilliseconds,
                sourceText: srcText,
                targetText: tgtText,
                alignmentConfidence: hasBoth ? 1.0 : 0.0,
                alignmentStatus: hasBoth ? .matched : .unmatched
            ))
            nextID += 1
        }

        return result
    }
}

// MARK: - Supporting Types

private struct AlignmentSegment {
    let matches: [CueAlignmentMatch]
    let master: Int  // 0 = source, 1 = target
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
```

**Step 2: Build**

```bash
xcodebuild -project SubtitleStudio.xcodeproj -scheme SubtitleStudio -destination 'platform=macOS' build
```

Expected: Build fails at callers. Proceed to Task 6.

---

### Task 6: Update WorkflowViewModel for Pipeline Subscription

**Files:**
- Modify: `SubtitleStudio/ViewModels/WorkflowViewModel.swift`

This is the largest refactor. We'll do it in sub-steps.

**Step 6a: Add pipeline property**

At the top of the class (near line 82), add:

```swift
private var mergeEventStream: AsyncStream<MergeEvent>?
private var qualityEventStream: AsyncStream<QualityEvent>?
```

**Step 6b: Replace startBackgroundMerge() with pipeline-based version**

Replace `startBackgroundMerge()` (lines 1162-1202) with a method that subscribes to the pipeline stream:

```swift
private func startBackgroundMerge(
    source: SubtitleDocument,
    target: SubtitleDocument,
    cacheKey: String,
    vadResult: VADArbitrationResult? = nil
) {
    mergePreviewTask?.cancel()
    let token = UUID()
    mergePreviewTaskToken = token

    let (mergeStream, qualityStream) = pipeline.run(
        source: source,
        target: target,
        vadResult: vadResult,
        outputFormat: exportFormat
    )
    self.mergeEventStream = mergeStream
    self.qualityEventStream = qualityStream

    Task { [weak self] in
        guard let self else { return }

        var displayedCues: [BilingualCue] = []

        for await event in mergeStream {
            guard self.mergePreviewTaskToken == token else { return }

            await MainActor.run {
                switch event {
                case .alignmentComplete(let report):
                    self.alignmentReport = report

                case .segmentBuilt(let segment):
                    if segment.master == 0 {
                        self.log("Segment \(self.previewState.fullCues?.count ?? 0): source master")
                    } else {
                        self.log("Segment: target master")
                    }

                case .pageReady(let cues, let page, _):
                    displayedCues.append(contentsOf: cues)
                    self.previewState.fullCues = displayedCues
                    if page <= 1 {
                        self.previewState.displayedCues = Array(displayedCues.prefix(50))
                    }
                    self.previewState.totalCueCount = self.mergedDocument?.cues.count

                case .mergeComplete(let document):
                    self.mergedDocument = document
                    self.mergedDocumentCache[cacheKey] = document
                    self.previewState.fullCues = document.cues
                    self.previewState.displayedCues = Array(document.cues.prefix(50))
                    self.previewState.totalCueCount = document.cues.count
                    self.previewState.isBuildingFullMerge = false
                }
            }
        }

        for await event in qualityStream {
            guard self.mergePreviewTaskToken == token else { return }

            await MainActor.run {
                if case .evaluationComplete(let report) = event {
                    self.qualityReport = report
                    self.isQualityEvaluationPending = false
                }
            }
        }
    }
}
```

**Step 6c: Remove buildFastMergedPage()**

Delete the entire `buildFastMergedPage()` method (lines 1256-1281) and its helper `fastMatchTargetCue()`.

**Step 6d: Update refreshPreviewForCurrentState()**

In `refreshPreviewForCurrentState()` (line 727), remove the `publishInitialBilingualPreview()` call and fast-preview logic. Instead, when both documents are ready, directly call the pipeline:

```swift
// Replace lines 742-745 (the bilingual preview block) with:
if let source = effectiveSource, let targetDoc = effectiveTarget {
    let cacheKey = currentMergeCacheKey
    startBackgroundMerge(
        source: source,
        target: targetDoc,
        cacheKey: cacheKey,
        vadResult: lastVADResult
    )
    if !isDraftPreview {
        // Quality is handled by the pipeline alongside merge
    }
    previewState.isBuildingFullMerge = true
}
```

**Step 6e: Remove publishInitialBilingualPreview()**

Delete `publishInitialBilingualPreview()` (line 1086) — this was the fast preview entry point.

**Step 6f: Fix exportFormatChanged()**

In `exportFormatChanged()` (line 363), remove `publishInitialBilingualPreview()` call and the merge restart. Only re-render:

```swift
func exportFormatChanged() {
    // No longer re-merges on format change.
    // The merged document stays; only re-rendering on export differs.
    log("Export format changed to \(exportFormat.fileExtension)")
}
```

**Step 6g: Fix currentMergeCacheKey**

Remove `exportFormat.rawValue` from cache key (line 1993):

```swift
private var currentMergeCacheKey: String {
    "\(cards[0].selectedCandidateID ?? "nil")-\(cards[1].selectedCandidateID ?? "nil")"
}
```

**Step 6h: Remove `qualityEvaluationTaskToken`**

Remove `qualityEvaluationTaskToken` (line 86) — the quality stream now uses `mergePreviewTaskToken` for its staleness guard. Keep `mergePreviewTaskToken`; it is still the single token for both streams.

**Step 6i: Build**

```bash
xcodebuild -project SubtitleStudio.xcodeproj -scheme SubtitleStudio -destination 'platform=macOS' build
```

Expected: May have compilation errors from stale references. Fix iteratively.

---

### Task 7: Refactor SubtitleQualityService — Accept AlignmentReport

**Files:**
- Modify: `SubtitleStudio/Services/ServiceProtocols.swift:47-49`
- Modify: `SubtitleStudio/Services/SubtitleQualityService.swift`

**Step 1: Update protocol**

```swift
protocol SubtitleQualityScoringServicing {
    func evaluate(
        source: SubtitleDocument,
        candidate: SubtitleDocument,
        targetLanguage: LanguageOption,
        alignmentReport: AlignmentReport?  // new: if nil, compute internally
    ) -> SubtitleQualityReport
}
```

**Step 2: Update SubtitleQualityService**

Add the parameter and skip re-alignment when `alignmentReport` is provided. Find the line where `aligner.align()` is called and guard it:

```swift
func evaluate(
    source: SubtitleDocument,
    candidate: SubtitleDocument,
    targetLanguage: LanguageOption,
    alignmentReport: AlignmentReport? = nil
) -> SubtitleQualityReport {
    let report = alignmentReport ?? aligner.align(source: source, target: candidate)
    // ... rest of evaluation uses `report` as before
}
```

**Step 3: Update MergePipeline to pass report**

In `MergePipeline.run()`, pass `report` to `qualityService.evaluate()`.

**Step 4: Build**

---

### Task 8: Recursive Subtitle Discovery

**Files:**
- Modify: `SubtitleStudio/Services/SubtitleInventoryService.swift`
- Modify: `SubtitleStudio/Services/ServiceProtocols.swift:7-9` (add streaming variant)

**Step 1: Add recursive scan helper**

In `SubtitleInventoryService`:

```swift
private func discoverSidecarFiles(
    from videoURL: URL,
    supportedExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "txt"]
) -> [URL] {
    let videoDir = videoURL.deletingLastPathComponent()
    let videoStem = videoURL.deletingPathExtension().lastPathComponent
    let fileManager = FileManager.default

    guard let enumerator = fileManager.enumerator(
        at: videoDir,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }

    var found: [(url: URL, relativePath: String, matchQuality: Int)] = []

    for case let fileURL as URL in enumerator {
        let ext = fileURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { continue }

        let relativePath = fileURL.path.replacingOccurrences(of: videoDir.path + "/", with: "")
        let stem = fileURL.deletingPathExtension().lastPathComponent

        let matchQuality: Int
        if fileURL.deletingLastPathComponent() == videoDir {
            matchQuality = stem.contains(videoStem) ? 3 : 2
        } else {
            matchQuality = stem.contains(videoStem) ? 1 : 0
        }

        found.append((fileURL, relativePath, matchQuality))
    }

    // Sort by match quality descending, then by relative path depth
    found.sort {
        if $0.matchQuality != $1.matchQuality { return $0.matchQuality > $1.matchQuality }
        let depth0 = $0.relativePath.split(separator: "/").count
        let depth1 = $1.relativePath.split(separator: "/").count
        return depth0 < depth1
    }

    return found.map(\.url)
}
```

**Step 2: Update buildInventory**

Replace the sidecar section (lines 33-49) to use `discoverSidecarFiles(from:)` instead of `report.localSubtitleSidecars`. Also set `kind` and `relativePath` on each candidate:

```swift
let sidecarURLs = discoverSidecarFiles(from: videoURL) // where videoURL is the source video
// ... for each URL, create candidate with kind and relativePath set
candidate.kind = classifyCandidateKind(candidate)
candidate.relativePath = relativePath
```

**Step 3: Add classification helper**

```swift
private func classifyCandidateKind(_ candidate: SubtitleCandidate) -> CueKind {
    let title = candidate.sourceLabel.lowercased()
    if title.contains("forced") || title.contains("fn") {
        return .forcedNarrative
    }
    if title.contains("sdh") || title.contains("hearing impaired")
        || title.contains("closed caption") || title.contains("[cc]") {
        return .sdh
    }
    return .unknown // Will be refined after document load with per-cue classification
}
```

**Step 4: Build**

---

### Task 9: Update SileroVADService — Parallel Extraction

**Files:**
- Modify: `SubtitleStudio/Infrastructure/Media/SileroVADService.swift:99-120`

**Step 1: Replace sequential for loop with TaskGroup**

Replace the `for (idx, range) in ranges.enumerated()` loop (lines 99-120) with:

```swift
let allSegments = try await withThrowingTaskGroup(
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
                return [] // Continue with other ranges
            }
        }
    }

    var results: [VADSpeechSegment] = []
    for try await segments in group {
        results.append(contentsOf: segments)
    }
    return results
}
```

**Step 2: Build**

---

### Task 10: Wire MergePipeline into AppEnvironment

**Files:**
- Modify: `SubtitleStudio/App/AppEnvironment.swift`

**Step 1: Add pipeline property**

After line 15 (`translationProviders`), add:

```swift
var pipeline: MergePipeline
```

**Step 2: Wire in .live**

After line 51 (translation providers wire-up), add:

```swift
pipeline = MergePipeline(mergeService: mergeService, qualityService: qualityService)
```

**Step 3: Build**

---

### Task 11: Update Views — Origin/Kind Badges + Streaming Pages

**Files:**
- Modify: `SubtitleStudio/Views/SubtitleWorkspaceView.swift`
- Modify: `SubtitleStudio/Views/CueTableView.swift`

**Step 1: Add origin/kind badges to candidate display**

`WorkflowSidebarView.swift` has no candidate display. Candidates are shown in
`SubtitleWorkspaceView.swift`, `useAvailablePanel` (lines 85–120). The `ForEach(candidates)`
block at line 110 renders each candidate as `Text(candidate.displayTitle)`. Replace that with
an `HStack` that appends origin and kind badges:

```swift
// Origin badge
switch candidate.origin {
case .embedded: 
    Label("Embedded", systemImage: "opticaldisc")
        .font(.caption2)
        .foregroundStyle(.blue)
case .localFile:
    Label("Sidecar", systemImage: "doc.text")
        .font(.caption2)
        .foregroundStyle(.green)
default:
    EmptyView()
}

// Kind badge
if let kind = candidate.kind {
    switch kind {
    case .sdh:
        Text("SDH")
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(.orange.opacity(0.2))
            .cornerRadius(3)
    case .forcedNarrative:
        Text("Forced")
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(.purple.opacity(0.2))
            .cornerRadius(3)
    case .ad:
        Text("Ad")
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(.red.opacity(0.2))
            .cornerRadius(3)
    default:
        EmptyView()
    }
}
```

**Step 2: Update CueTableView for streaming pages**

In `CueTableView`, replace the static cue list with a view that appends pages. When `previewState.fullCues` is updated (page arrives), the table re-renders. No structural jump since the new cues have the same format as the first page. Simply observe `previewState.displayedCues` or `previewState.fullCues` as currently done — the streaming effect comes from the ViewModel updating these incrementally.

**Step 3: Build**

---

### Task 12: Remove Old Code Paths

**Files:**
- Modify: `SubtitleStudio/ViewModels/WorkflowViewModel.swift`

**Step 1: Delete fast preview remnants**

- Delete `buildFastMergedPage()` method if not already deleted
- Delete `fastMatchTargetCue()` helper
- Delete `publishInitialBilingualPreview()` method
- Delete any `fastPreviewToken` / `fastPreviewTaskToken` properties

**Step 2: Delete old merge task management and quality method**

- If the old `startBackgroundMerge` variant (non-pipeline) still exists alongside the new one, delete it.
- Delete `startBackgroundQualityEvaluation()` (line 1204+) and all its call sites. Quality is now
  driven by the pipeline quality stream inside `startBackgroundMerge`. Leaving it wired means NW
  alignment would run a second time independently.

**Step 3: Delete duplicate quality alignment**

In `SubtitleQualityService`, if the old path (re-align internally) still exists as a default parameter, ensure the pipeline always passes the report.

**Step 4: Build and verify**

```bash
xcodegen generate && xcodebuild -project SubtitleStudio.xcodeproj -scheme SubtitleStudio -destination 'platform=macOS' build
```

Expected: Clean build with no warnings from removed code.

---

### Verification

After all tasks complete, verify end-to-end:

1. **Build:** `xcodegen generate && xcodebuild -project SubtitleStudio.xcodeproj -scheme SubtitleStudio -destination 'platform=macOS' build`
2. **Discovery:** Launch app → load a video from a directory with subfolder subtitles → verify candidates stream in with origin badges (Embedded/Sidecar) and kind badges (SDH/Forced)
3. **Merge preview:** Select source + target → verify merge runs once, pages stream in progressively, no structural jump in preview
4. **Format switch:** Change export format SRT→ASS→VTT → verify instant switch (no re-merge, no loading spinner)
5. **VAD arbitration:** Load a pair with timing mismatch → run VAD analysis → verify preview shows fewer fragments (single-sided blanks) than without VAD. Master switches should be visible in the log.
6. **Quality:** Verify quality report appears after merge without re-aligning.
