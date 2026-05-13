# Pipeline Restructure: VAD-Arbitrated Subtitle Merging

Design for restructuring the subtitle processing pipeline around a unified async stream architecture, with VAD-arbitrated merge, enhanced subtitle discovery, and streaming preview.

Status: **Design — approved**.

## Motivation

The current pipeline has structural problems:

1. **Dual preview code paths**: a fast positional-match preview runs first, then a full Needleman-Wunsch merge replaces it. The two produce different timeline boundaries, causing visible UI jumps.
2. **Duplicate alignment**: `SubtitleMergeService.merge()` runs `alignIteratively()` (1-3 NW passes), then `SubtitleQualityService.evaluate()` independently re-aligns the same pair.
3. **Format change triggers re-merge**: switching SRT→ASS→VTT redoes all alignment work, but the merge output is format-agnostic — only rendering differs.
4. **Merge fragmentation**: the current timeline construction slices at every boundary from both tracks, producing many fragments where only one side has text.
5. **Limited subtitle discovery**: only same-directory stem-matching sidecar files are found. Subfolder subtitles are invisible.
6. **Sequential VAD extraction**: audio ranges are extracted one at a time.

## Architecture

The pipeline is restructured as a unified async stream flowing through discrete stages:

```
Video URL
  │
  ▼
Stage 1: Discovery ──→ AsyncStream<DiscoveryEvent>
  │   Recursive scan, embedded + sidecar, streaming candidates
  ▼
Stage 2: Loading ──→ AsyncStream<LoadEvent>
  │   Parallel document load for both cards
  ▼
Stage 3: Optional VAD ──→ AsyncStream<MergeEvent>
  │   Parallel audio extraction (TaskGroup), cue scoring
  ▼
Stage 4: Segment Merge ──→ AsyncStream<MergeEvent>
  │   NW alignment → VAD arbitration → segment-based timeline → streaming pages
  ▼
Stage 5: Quality ──→ AsyncStream<QualityEvent>
  │   Reuses merge's AlignmentReport, no re-alignment
  ▼
Stage 6: Export
      Format change only re-renders, never re-merges
```

### Key structural changes

| Current | Restructured |
|---------|-------------|
| `WorkflowViewModel` calls services directly with `Task {}` | ViewModel subscribes to `AsyncStream` pipelines |
| Discovery is synchronous, blocks on ffprobe completion | Discovery streams candidates as found — UI populates incrementally |
| Fast preview → full merge (two code paths) | Single merge path, pages streamed |
| Quality re-runs NW alignment independently | Quality receives the merge's `AlignmentReport` |
| Format change triggers full re-merge | Format change only re-renders the already-merged document |
| VAD extraction is sequential `for` loop | VAD extraction uses `TaskGroup` for parallel ranges |
| Timeline sliced at all boundaries from both tracks | Segment-based — one master per segment, one set of boundaries |

## VAD-Arbitrated Segment Merge

### The Fragmentation Problem

Current `buildTimelineCues()` collects all time points from both timelines and slices at every one. When source and target have different segmentation, this produces many tiny fragments with empty text on one side.

### Segment-Based Approach

VAD speech overlap scores determine which track is master per region:

1. **Run NW alignment once** — VAD scores fed into `pairConfidence()` via `vadAgreementTerm`
2. **Partition into segments** — segment boundaries at master switches, gaps, or unmatched cues
3. **Build per-segment timeline** — use only the master track's cue boundaries
4. **Fill secondary text** — text from the other track assigned to the covering master cue
5. **Stream pages** — emit `Page<BilingualCue>` as each segment completes (e.g., 50 cues)

```
Segment 1 (source master, src VAD=0.88 vs tgt VAD=0.74):
  Source:  |──A──|  |──B──|
  Target:  |─1─| |─2─|
  Output:  |──A──|  |──B──|
           text: A+1  text: B+2

Segment 2 (target master, src VAD=0.55 vs tgt VAD=0.91):
  Source:  |──C──|
  Target:  |─3─| |─4─|
  Output:  |─3─| |─4─|
           text: C+3  text: (gap)+4
```

Master selection per aligned pair:
```
if source.cueVADScore > target.cueVADScore + 0.15: master = source
elif target.cueVADScore > source.cueVADScore + 0.15: master = target
else: master = whichever has higher document-level average VAD score
```

## Subtitle Discovery

### Recursive Scan + Relaxed Match

From the video's directory, recursively scan all subdirectories for subtitle files. All subtitle files are surfaced regardless of filename match.

### Candidate Tagging

Each candidate gets:

**Origin:**
```swift
enum SubtitleOrigin {
    case embedded(trackIndex: Int, codec: String)
    case sidecar(url: URL, relativePath: String)
}
```

**Kind** (classified at discovery time, text-only):
```swift
enum SubtitleKind {
    case dialogue
    case sdh            // brackets, speaker labels, music symbols
    case forcedNarrative // track title "Forced" or "FN"
    case ad             // spam patterns
    case unknown
}
```

### Ranking

1. Stem match + same directory — highest (current behavior)
2. Stem match + subdirectory — high
3. No stem match + subdirectory (relaxed) — medium, sorted by filename similarity
4. No stem match + deep path — low

### Streaming

Candidates stream to the UI as discovered — the candidate list populates incrementally.

## Pipeline Event Streams

Defined in new `PipelineEvents.swift`:

```swift
enum DiscoveryEvent {
    case scanning(path: String)
    case candidateFound(SubtitleCandidate)
    case discoveryComplete(candidates: [SubtitleCandidate])
}

enum LoadEvent {
    case loadProgress(card: CardIndex, fraction: Double)
    case documentReady(card: CardIndex, document: SubtitleDocument)
}

enum MergeEvent {
    case alignmentComplete(report: AlignmentReport)
    case segmentBuilt(segment: MergeSegment, master: CardIndex)
    case pageReady(cues: [BilingualCue], page: Int)
    case mergeComplete(document: MergedSubtitleDocument)
}

enum QualityEvent {
    case evaluationComplete(report: SubtitleQualityReport)
}
```

## Files Changed

| File | Change |
|------|--------|
| **New** `Services/PipelineEvents.swift` | Event types for all stages |
| **New** `Services/MergePipeline.swift` | Pipeline coordinator actor |
| `Domain/Models.swift` | Add `SubtitleOrigin`, `SubtitleKind`, `MergeSegment`; fields on `SubtitleCandidate` |
| `Services/ServiceProtocols.swift` | Update `SubtitleMergingServicing` for streaming; update `SubtitleQualityServicing` to accept `AlignmentReport` |
| `Services/SubtitleInventoryService.swift` | Recursive scan, streaming discovery, cue classification |
| `Services/SubtitleMergeService.swift` | Segment-based merge with VAD arbitration; single streaming path |
| `Services/SubtitleAlignmentService.swift` | Pass alignment report through; remove duplicate alignment from quality path |
| `Services/SubtitleQualityService.swift` | Accept pre-computed `AlignmentReport` instead of re-aligning |
| `Services/SileroVADService.swift` | `TaskGroup` for parallel extraction |
| `App/AppEnvironment.swift` | Wire `MergePipeline` into `.live` |
| `ViewModels/WorkflowViewModel.swift` | Replace task-based orchestration with pipeline subscription |
| `Views/WorkflowSidebarView.swift` | Show origin badge (embedded/sidecar), kind badge (SDH/forced/ad) |
| `Views/WorkflowInspectorView.swift` | Format change → re-render only, no re-merge |
| `Views/CueTableView.swift` | Append pages, no structural replacement |
| `project.yml` | Add `PipelineEvents.swift` and `MergePipeline.swift` to sources |

## Migration Path

1. Add new types (`SubtitleOrigin`, `SubtitleKind`, event enums) to `Models.swift` — non-breaking additions
2. Add `PipelineEvents.swift` + `MergePipeline.swift` — new files, no existing code changed
3. Refactor `SubtitleInventoryService` for recursive scan — existing callers still get `[SubtitleCandidate]`
4. Refactor `SubtitleMergeService` for segment-based streaming — new method alongside old
5. Refactor `WorkflowViewModel` to use pipeline — switch over once streaming is stable
6. Update views for badges and streaming pages
7. Remove old code paths (fast preview, duplicate alignment in quality)

## Verification

- Build: `xcodegen generate && xcodebuild -project BridgeSub.xcodeproj -scheme BridgeSub -destination 'platform=macOS' build`
- UI: load a video → verify candidates stream in incrementally with origin/kind badges → select source+target → verify merge pages stream in without structural jumps → switch export format → verify no re-merge (instant format switch)
- VAD alignment: load a pair with known timing mismatch → observe fragment count without VAD vs. with VAD → verify VAD-arbitrated merge shows fewer single-sided fragments in preview
