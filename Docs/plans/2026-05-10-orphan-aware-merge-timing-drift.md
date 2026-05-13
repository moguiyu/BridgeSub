# Orphan-Aware Merge with Timing Drift Detection — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Inject unmatched secondary-track cues (Chinese title cards, era markers, post-credits tail) into the merged output as secondary-only BilingualCues, and detect + correct systematic timing drift between source and target tracks.

**Architecture:** Three-part extension of the existing VAD-arbitrated merge pipeline. (1) `AlignmentReport` gains three new fields for orphan IDs and detected drift offset. (2) `SubtitleMergeService.merge()` collects unmatched secondary cues after segment building and injects them as `BilingualCue` with empty `sourceText`, sorted into the final timeline. (3) `normalizeSecondaryForTimelineMerge()` detects residual systematic drift from matched-pair deltas and applies a correction shift to the normalized target document. Quality service and inspector view surface the new data.

**Tech Stack:** Swift 6, `SubtitleAligner` (existing NW alignment), `SubtitleMergeService` (segment-based merge), `WorkflowInspectorView` (alignment rows pattern already exists). No new files — all changes are additive to existing files.

**Reference data (from "In the Blink of an Eye (2026)" analysis):**
- 120 Chinese cues dropped → should all appear as secondary-only after this change
- −43ms systematic timing drift → detected and corrected
- Post-credits Chinese tail (01:28:31→01:33:54, 323s) → injected

---

## Task 1: Extend `AlignmentReport` with orphan and drift fields

**Files:**
- Modify: `BridgeSub/Domain/Models.swift:1492–1510`

Current struct at line 1492:
```swift
struct AlignmentReport: Equatable, Sendable {
    let matches: [CueAlignmentMatch]
    let matchedCueRatio: Double
    let lowConfidenceCueRatio: Double
    let unmatchedCueRatio: Double
    let medianStartDeltaMilliseconds: Double
    let monotonicityViolations: Int
    let averageConfidence: Double

    static let empty = AlignmentReport(...)
}
```

**Step 1: Add three new fields to `AlignmentReport`**

Replace the struct with:
```swift
struct AlignmentReport: Equatable, Sendable {
    let matches: [CueAlignmentMatch]
    let matchedCueRatio: Double
    let lowConfidenceCueRatio: Double
    let unmatchedCueRatio: Double
    let medianStartDeltaMilliseconds: Double
    let monotonicityViolations: Int
    let averageConfidence: Double
    let detectedTimingOffsetMilliseconds: Int?
    let orphanedSourceCueIDs: Set<Int>
    let orphanedTargetCueIDs: Set<Int>

    static let empty = AlignmentReport(
        matches: [],
        matchedCueRatio: 0,
        lowConfidenceCueRatio: 0,
        unmatchedCueRatio: 1,
        medianStartDeltaMilliseconds: 0,
        monotonicityViolations: 0,
        averageConfidence: 0,
        detectedTimingOffsetMilliseconds: nil,
        orphanedSourceCueIDs: [],
        orphanedTargetCueIDs: []
    )
}
```

**Step 2: Fix `report(for:)` in `SubtitleAlignmentService.swift`**

The private `report(for:)` function at line ~242 constructs an `AlignmentReport`. Add three trailing arguments with defaults:

```swift
return AlignmentReport(
    matches: matches,
    matchedCueRatio: ...,
    lowConfidenceCueRatio: ...,
    unmatchedCueRatio: ...,
    medianStartDeltaMilliseconds: medianDelta,
    monotonicityViolations: ...,
    averageConfidence: ...,
    detectedTimingOffsetMilliseconds: nil,   // filled in by normalizer
    orphanedSourceCueIDs: [],                // filled in by merge service
    orphanedTargetCueIDs: []                 // filled in by merge service
)
```

**Step 3: Compile check**

```bash
xcodebuild -project BridgeSub.xcodeproj -scheme BridgeSub \
  -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'
```

Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add BridgeSub/Domain/Models.swift BridgeSub/Services/SubtitleAlignmentService.swift
git commit -m "feat: add timing drift and orphan fields to AlignmentReport"
```

---

## Task 2: Detect and correct residual timing drift in the normalizer

**Files:**
- Modify: `BridgeSub/Services/SubtitleAlignmentService.swift:194–240`

The normalization function already applies a large (>200ms) offset via `calculateOffset()`. This task adds a second, fine-grained detection pass for smaller systematic drifts (>30ms) using the matched pairs from the final alignment report.

**Step 1: Add private helper `detectResidualDrift(report:sourceCues:targetCues:)`**

Add this private method to `SubtitleAligner` (after `calculateOffset`, around line 355):

```swift
private func detectResidualDrift(
    report: AlignmentReport,
    sourceCues: [SubtitleCue],
    targetCues: [SubtitleCue]
) -> Int? {
    let sourceByID = Dictionary(uniqueKeysWithValues: sourceCues.map { ($0.id, $0) })
    let targetByID = Dictionary(uniqueKeysWithValues: targetCues.map { ($0.id, $0) })

    let deltas: [Int] = report.matches.compactMap { match in
        guard match.status == .matched || match.status == .lowConfidence,
              let targetID = match.targetCueID,
              let src = sourceByID[match.sourceCueID],
              let tgt = targetByID[targetID] else { return nil }
        return tgt.startMilliseconds - src.startMilliseconds
    }

    guard deltas.count >= 5 else { return nil }

    let sorted = deltas.sorted()
    let median = sorted.count.isMultiple(of: 2)
        ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        : sorted[sorted.count / 2]

    guard abs(median) > 30 else { return nil }

    // Require ≥80% of deltas to be within ±100ms of median (tight distribution)
    let tightCount = deltas.filter { abs($0 - median) <= 100 }.count
    guard Double(tightCount) / Double(deltas.count) >= 0.80 else { return nil }

    return median
}
```

**Step 2: Apply drift correction in `normalizeSecondaryForTimelineMerge()`**

After the existing normalization (around line 207, after `normalizedTarget` is computed), add:

```swift
// Detect and correct residual timing drift not caught by the large-offset pass
let residualDrift = detectResidualDrift(
    report: iterationResult.report,
    sourceCues: source.cues,
    targetCues: normalizedTarget.cues
)
let driftCorrectedTarget: SubtitleDocument
if let drift = residualDrift {
    driftCorrectedTarget = shiftCues(in: normalizedTarget, by: -drift)
} else {
    driftCorrectedTarget = normalizedTarget
}
```

Replace `normalizedTarget` with `driftCorrectedTarget` in the reference span computation and the returned `TimelineMergeNormalizationResult`.

Update the returned `AlignmentNormalizationResult` to capture the drift in the report:
```swift
let driftReport = AlignmentReport(
    matches: iterationResult.report.matches,
    matchedCueRatio: iterationResult.report.matchedCueRatio,
    lowConfidenceCueRatio: iterationResult.report.lowConfidenceCueRatio,
    unmatchedCueRatio: iterationResult.report.unmatchedCueRatio,
    medianStartDeltaMilliseconds: iterationResult.report.medianStartDeltaMilliseconds,
    monotonicityViolations: iterationResult.report.monotonicityViolations,
    averageConfidence: iterationResult.report.averageConfidence,
    detectedTimingOffsetMilliseconds: residualDrift,
    orphanedSourceCueIDs: [],   // filled in later by merge service
    orphanedTargetCueIDs: []    // filled in later by merge service
)

let normalization = AlignmentNormalizationResult(
    report: driftReport,   // ← use driftReport, not iterationResult.report
    iterations: iterationResult.iterations,
    detectedAds: iterationResult.detectedAds,
    appliedOffset: iterationResult.appliedOffset,
    primaryMatchedTextsBySourceCueID: primaryMatchedTextsBySourceCueID,
    referenceSpansBySourceCueID: referenceSpansBySourceCueID
)

return TimelineMergeNormalizationResult(
    normalization: normalization,
    normalizedTarget: driftCorrectedTarget   // ← use drift-corrected target
)
```

**Step 3: Compile check**

```bash
xcodebuild -project BridgeSub.xcodeproj -scheme BridgeSub \
  -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'
```

Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add BridgeSub/Services/SubtitleAlignmentService.swift
git commit -m "feat: detect and correct residual timing drift in subtitle normalizer"
```

---

## Task 3: Inject secondary orphan cues in `SubtitleMergeService.merge()`

**Files:**
- Modify: `BridgeSub/Services/SubtitleMergeService.swift:36–73`

After the main `for segment in segments { ... }` loop and the final page emission, inject orphaned secondary cues and re-sort the full cue list.

**Step 1: Collect orphaned secondary cues and inject them**

Replace the section after the main segment loop (currently ending around line 63 with the `remainingStart` emission) with this extended version:

```swift
// Collect secondary cues that were never matched (orphans)
let matchedTargetIDs = Set(report.matches.compactMap(\.targetCueID))
let orphanedTargetCues = targetCues.filter { !matchedTargetIDs.contains($0.id) }

// Build a set of matched time ranges for overlap detection
let matchedRanges = allCues.map { ($0.startMilliseconds, $0.endMilliseconds) }

var orphanBilingualCues: [BilingualCue] = []
for orphan in orphanedTargetCues {
    let text = orphan.plainText.normalizedSubtitleText
    guard !text.isEmpty else { continue }
    // Skip orphans that overlap an existing matched cue
    let overlaps = matchedRanges.contains {
        $0.0 < orphan.endMilliseconds && $0.1 > orphan.startMilliseconds
    }
    if overlaps { continue }
    orphanBilingualCues.append(BilingualCue(
        id: 0,  // renumbered below
        startMilliseconds: orphan.startMilliseconds,
        endMilliseconds: orphan.endMilliseconds,
        sourceText: "",        // no master-track text for this cue
        targetText: text,
        alignmentConfidence: 0.0,
        alignmentStatus: .unmatched
    ))
}

// Merge, sort by start time, renumber
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

// Build updated report with orphan IDs
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
```

Replace `alignmentReport: report` in the `MergedSubtitleDocument(...)` return with `alignmentReport: finalReport`.

**Note:** The streaming page callbacks (`onPage`) are emitted during segment iteration and don't include orphans. Orphans only appear in the final `MergedSubtitleDocument`. This is intentional — the streaming preview is a draft; the final document is authoritative.

**Step 2: Compile check**

```bash
xcodebuild -project BridgeSub.xcodeproj -scheme BridgeSub \
  -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'
```

Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add BridgeSub/Services/SubtitleMergeService.swift
git commit -m "feat: inject orphaned secondary cues into merged subtitle output"
```

---

## Task 4: Surface drift and orphan data in `SubtitleQualityService`

**Files:**
- Modify: `BridgeSub/Services/SubtitleQualityService.swift`

The quality service already reads `alignmentReport` fields to build notes. Add two more note generators at the end of the existing notes-building section.

**Step 1: Add timing drift and orphan recovery signals**

Find the section that builds `notes` (around the section computing `matchedCueRatio` signals). Add after the existing notes:

```swift
// Timing drift signal
if let driftMs = alignmentReport.detectedTimingOffsetMilliseconds {
    let sign = driftMs > 0 ? "+" : ""
    notes.append("Timing drift: \(sign)\(driftMs)ms detected and corrected")
}

// Orphan recovery signal
let orphanCount = alignmentReport.orphanedTargetCueIDs.count
if orphanCount > 0 {
    let totalTarget = candidate.cues.count
    let matchedCount = alignmentReport.matches.filter { $0.targetCueID != nil }.count
    let coverageAfter = totalTarget > 0
        ? Double(matchedCount + orphanCount) / Double(totalTarget)
        : 1.0
    notes.append("\(orphanCount) secondary cues recovered as secondary-only (coverage: \(Int((coverageAfter * 100).rounded()))%)")
}
```

**Step 2: Compile check**

```bash
xcodebuild -project BridgeSub.xcodeproj -scheme BridgeSub \
  -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'
```

Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add BridgeSub/Services/SubtitleQualityService.swift
git commit -m "feat: surface timing drift and orphan recovery in quality report"
```

---

## Task 5: Add computed properties to `WorkflowViewModel`

**Files:**
- Modify: `BridgeSub/ViewModels/WorkflowViewModel.swift` (near other `vad*` computed properties, around line 887)

**Step 1: Add three new computed properties**

Add after `var vadSpeechSegmentCount`:

```swift
var detectedTimingDriftLabel: String? {
    guard let offset = qualityReport?.alignmentReport.detectedTimingOffsetMilliseconds else { return nil }
    let sign = offset > 0 ? "+" : ""
    return "\(sign)\(offset)ms (corrected)"
}

var orphanedSecondaryCount: Int {
    qualityReport?.alignmentReport.orphanedTargetCueIDs.count ?? 0
}

var secondaryCoverageAfterInjection: Double {
    guard let report = qualityReport else { return 0 }
    let alignment = report.alignmentReport
    let totalTarget = mergedDocument.map { doc in
        // Approximate: matched + orphaned / total secondary cues that were in original target
        let matched = alignment.matches.filter { $0.targetCueID != nil }.count
        let orphaned = alignment.orphanedTargetCueIDs.count
        let total = matched + orphaned + alignment.orphanedSourceCueIDs.count
        return total > 0 ? Double(matched + orphaned) / Double(total) : 1.0
    } ?? 0
    return totalTarget
}
```

**Note:** `secondaryCoverageAfterInjection` uses an approximation because the ViewModel doesn't have direct access to the original secondary document after merge completes. A more accurate approach would require persisting the source/target document cue counts — consider adding `secondaryCueCount: Int` to `MergedSubtitleDocument` in a future task if precision is needed. For now, the orphan recovery note in the quality report (Task 4) provides the accurate percentage.

Simpler version that avoids the approximation issue:

```swift
var secondaryCoverageAfterInjection: Double {
    guard let report = qualityReport else { return 0 }
    let alignment = report.alignmentReport
    let matched = alignment.matches.filter { $0.targetCueID != nil }.count
    let orphaned = alignment.orphanedTargetCueIDs.count
    let total = matched + orphaned
    return total > 0 ? Double(matched + orphaned) / Double(total) : 1.0
}
```

**Step 2: Compile check**

```bash
xcodebuild -project BridgeSub.xcodeproj -scheme BridgeSub \
  -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'
```

Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add BridgeSub/ViewModels/WorkflowViewModel.swift
git commit -m "feat: add timing drift and orphan coverage computed properties to ViewModel"
```

---

## Task 6: Add alignment rows to `WorkflowInspectorView`

**Files:**
- Modify: `BridgeSub/Views/WorkflowInspectorView.swift` (after existing alignment rows, around line 412)

The existing pattern uses `alignmentRow(title:value:systemImage:tone:)` at line 691. Add two more rows after the existing five alignment rows (matched %, low-confidence %, median delta, monotonicity, average confidence).

**Step 1: Add timing drift and recovered cues rows**

After the last existing `alignmentRow` call (around line 412), add:

```swift
if let driftLabel = viewModel.detectedTimingDriftLabel {
    alignmentRow(
        title: "Timing drift",
        value: driftLabel,
        systemImage: "clock.arrow.2.circlepath",
        tone: .info
    )
}

if viewModel.orphanedSecondaryCount > 0 {
    alignmentRow(
        title: "Recovered cues",
        value: "\(viewModel.orphanedSecondaryCount) secondary-only injected",
        systemImage: "plus.bubble",
        tone: .success
    )
}
```

**Step 2: Compile check**

```bash
xcodebuild -project BridgeSub.xcodeproj -scheme BridgeSub \
  -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'
```

Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add BridgeSub/Views/WorkflowInspectorView.swift
git commit -m "feat: show timing drift correction and recovered cue count in inspector"
```

---

## Task 7: Write design doc and final commit

**Step 1: Verify the full build one more time**

```bash
xcodegen generate && xcodebuild -project BridgeSub.xcodeproj -scheme BridgeSub \
  -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

**Step 2: Commit the plan doc itself**

```bash
git add Docs/plans/2026-05-10-orphan-aware-merge-timing-drift.md
git commit -m "docs: orphan-aware merge with timing drift detection plan"
```

---

## Task 8: Verify against real subtitle files

**Step 1: Run merge and check output cue count**

Open BridgeSub. Load:
- Source (Card 1): embedded English from `/Volumes/Media/Movie/In the Blink of an Eye (2026)/In the Blink of an Eye (2026) 2160p AAC.mkv`
- Target (Card 2): `/Volumes/Media/Movie/In the Blink of an Eye (2026)/[zmk.pw]In.the.Blink.of.an.Eye.2026.1080p.DSNP.WEB-DL.DDP5.1.H.264-FLUX@horan/In.the.Blink.of.an.Eye.2026.1080p.DSNP.WEB-DL.DDP5.1.H.264-FLUX.chs.srt`

Export merged SRT. Then run:

```bash
MERGED="/Volumes/Media/Movie/In the Blink of an Eye (2026)/In the Blink of an Eye (2026) 2160p AAC.en-zh.srt"
python3 << 'EOF'
import re
def parse_srt(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        content = f.read()
    blocks = re.split(r'\n\n+', content.strip())
    cues = []
    for block in blocks:
        lines = block.strip().split('\n')
        for i, l in enumerate(lines):
            m = re.match(r'(\d{2}:\d{2}:\d{2}[,\.]\d{3}) --> (\d{2}:\d{2}:\d{2}[,\.]\d{3})', l)
            if m:
                text = '\n'.join(lines[i+1:]).strip()
                def ts(s):
                    s=s.replace(',','.'); h,mi,rest=s.split(':'); sec,ms=rest.split('.')
                    return int(h)*3600000+int(mi)*60000+int(sec)*1000+int(ms[:3])
                cues.append((ts(m.group(1)),ts(m.group(2)),text))
                break
    return cues

import sys
merged = parse_srt(sys.argv[1])
is_zh = lambda t: any('一'<=c<='鿿' for c in t)
is_en = lambda t: bool(re.search(r'[a-zA-Z]{3,}', t))
both = [c for c in merged if is_en(c[2]) and is_zh(c[2])]
en_only = [c for c in merged if is_en(c[2]) and not is_zh(c[2])]
zh_only = [c for c in merged if is_zh(c[2]) and not is_en(c[2])]
print(f"Total cues: {len(merged)} (was 1037 before)")
print(f"Both EN+ZH: {len(both)} (was 723)")
print(f"EN-only: {len(en_only)}")
print(f"ZH-only: {len(zh_only)} (was 11, should be ~120 more)")
last = merged[-1]
print(f"Last cue: {last[1]//60000:02d}:{last[1]//1000%60:02d} (was 01:28:31, should now extend to ~01:33:54)")
EOF
```

**Expected results:**
- Total cues: ~1140+ (1037 + ~120 orphans, minus any overlapping ones)
- ZH-only: ~130+ (was 11)
- Last cue time: past 01:28:31 (post-credits tail injected)

**Step 2: Verify specific orphaned content is present**

```bash
grep -n "公元前4万5千年\|尼安德塔人\|记住，记住\|索恩\|赫拉" "$MERGED" | head -10
```

Expected: matches found around timestamps 00:02:33–00:03:45

**Step 3: Check quality report in UI**

In the inspector, look for:
- "Timing drift: −43ms detected and corrected" (or similar)
- "N secondary cues recovered as secondary-only (coverage: 100%)"

**Step 4: Verify timing correction numerically**

```bash
ffmpeg -v quiet -i "/Volumes/Media/Movie/In the Blink of an Eye (2026)/In the Blink of an Eye (2026) 2160p AAC.mkv" \
  -map 0:s:0 -f srt /tmp/blink_en_check.srt 2>/dev/null
python3 << 'EOF'
import re, sys
def parse_srt(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        content = f.read()
    blocks = re.split(r'\n\n+', content.strip())
    cues = []
    for block in blocks:
        lines = block.strip().split('\n')
        for i, l in enumerate(lines):
            m = re.match(r'(\d{2}:\d{2}:\d{2}[,\.]\d{3}) --> (\d{2}:\d{2}:\d{2}[,\.]\d{3})', l)
            if m:
                text = '\n'.join(lines[i+1:]).strip()
                def ts(s):
                    s=s.replace(',','.'); h,mi,rest=s.split(':'); sec,ms=rest.split('.')
                    return int(h)*3600000+int(mi)*60000+int(sec)*1000+int(ms[:3])
                cues.append((ts(m.group(1)),ts(m.group(2)),text))
                break
    return cues

embedded = parse_srt('/tmp/blink_en_check.srt')
merged = parse_srt('/Volumes/Media/Movie/In the Blink of an Eye (2026)/In the Blink of an Eye (2026) 2160p AAC.en-zh.srt')
is_en = lambda t: bool(re.search(r'[a-zA-Z]{3,}', t))
merged_en = [(s,e,t) for s,e,t in merged if is_en(t)]
offsets = []
for es,ee,et in embedded[:50]:
    hits = [(ms,me,mt) for ms,me,mt in merged_en if abs(ms-es)<=200]
    if hits:
        best = min(hits, key=lambda c: abs(c[0]-es))
        offsets.append(best[0]-es)
print(f"Timing offset avg (first 50 matched): {sum(offsets)//max(len(offsets),1):+d}ms")
print(f"  (was -43ms before fix; should be ≈0ms after drift correction)")
EOF
```

Expected: offset avg ≈ 0ms (was −43ms)

---

## Critical File Summary

| File | Lines Changed | Change |
|------|--------------|--------|
| `BridgeSub/Domain/Models.swift` | ~1492–1510 | Add 3 fields to `AlignmentReport` + update `.empty` |
| `BridgeSub/Services/SubtitleAlignmentService.swift` | ~242, ~355, ~194–240 | Add defaults to `report(for:)`, add `detectResidualDrift()`, apply in normalizer |
| `BridgeSub/Services/SubtitleMergeService.swift` | ~36–73 | Orphan collection, injection, re-sort, renumber, finalReport |
| `BridgeSub/Services/SubtitleQualityService.swift` | ~80–110 | Two new note generators |
| `BridgeSub/ViewModels/WorkflowViewModel.swift` | ~910 | Three new computed properties |
| `BridgeSub/Views/WorkflowInspectorView.swift` | ~412 | Two new `alignmentRow` calls |
