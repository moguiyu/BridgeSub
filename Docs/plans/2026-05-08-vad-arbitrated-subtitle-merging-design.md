# VAD-Arbitrated Subtitle Timeline Merging

Design for using voice activity detection (VAD) to improve subtitle alignment and merging. Solves timeline misalignment between two subtitle tracks of different languages by using the actual audio as an independent ground truth for speech boundaries.

Status: **Design — not yet implemented**.

## Motivation

The existing `SubtitleAligner` uses Needleman-Wunsch DP alignment based solely on temporal overlap between cues. It works well when both subtitle tracks share similar timing, but fails in common real-world scenarios:

1. **SDH subtitles**: sound descriptions and speaker labels with no corresponding speech produce false matches
2. **Different subtitle editions**: one subtitle was timed for a different cut of the film
3. **Merged/split cues**: one language uses one cue per sentence while another splits into two
4. **Small accumulated drift**: timing errors compound over the duration of a film
5. **Audio codec duplication**: multi-language releases contain multiple audio tracks (TrueHD + AC3 for the same language); the smaller codec should be preferred for analysis

The key insight: **don't synthesize a new timeline — use VAD to arbitrate between the two existing timelines**.

## Research Data

Sampled 60 videos across 176 movies and 908 TV episodes. Key findings from 303 embedded subtitle tracks:

| Metric | Finding |
|--------|---------|
| `subrip` (SRT) codec | 93% — embedded text is almost always clean |
| `hearing_impaired` disposition flag | 4.3% of tracks |
| SDH detected via track **title** | 8.6% of tracks |
| **SDH tracks missed by disposition flag** | **50%** — flag is unreliable |
| Forced Narrative tracks | 1.7%, mostly title "Forced" |
| Most common SDH title patterns | `SDH`, `English [SDH]`, `English (SDH)`, `English SDH` |

Conclusion: title-based SDH/Forced detection is essential. Disposition flags alone miss 50% of SDH tracks.

## Architecture

### Where It Fits

Runs as an optional pre-alignment phase, before `SubtitleAligner.alignIteratively()`. Triggered:

- **Automatically** when first-pass DP alignment returns `matchedCueRatio < 0.70`
- **Manually** when user requests "analyze with voice"

Sits in `SubtitleMergeService.merge()`, between document loading and the aligner call.

```
Video + Sub A + Sub B
  │
  ├─ 1. Cue Classification (text-only, fast)
  │     └─ Classify each cue: .dialogue / .sdh / .forcedNarrative / .ad
  │
  ├─ 2. Audio Track Selection
  │     └─ User picks or auto-selects best audio channel
  │
  ├─ 3. Stratified VAD Sampling
  │     └─ Extract audio only at merged cue regions, run Silero VAD
  │
  ├─ 4. Per-Cue VAD Scoring
  │     └─ Score each cue against VAD speech segments
  │
  ├─ 5. Piecewise Arbitration
  │     └─ Per-region: choose the subtitle with better speech alignment
  │
  └─ 6. Merge with VAD-weighted confidences
        └─ Feed into existing SubtitleAligner + SubtitleMergeService
```

### Phase 1: Cue Classification (Text-Only)

Classify every cue before alignment. No audio needed at this stage.

| CueKind | Detection | Merge behavior |
|---------|-----------|----------------|
| `.sdh` | Track title contains `SDH`, `hearing impaired`, `closed caption`, or `CC`. Per-cue: brackets, parentheses, `♪`, speaker prefix (`JOHN:`), music descriptors | Strip SDH portions for alignment; keep original for display |
| `.forcedNarrative` | Track title contains `Forced` or `FN` | Keep independent, don't DP-align |
| `.ad` | Existing text patterns (`yts`, `rarbg`, `www.`, `torrent`, etc.) + short duration (<5s) | Drop from alignment |
| `.dialogue` | Everything else | Normal DP alignment |

Mixed cues (e.g., `[door slams] I can't do this.`) are split: SDH portion stripped for alignment, dialogue kept.

After VAD sampling: SDH sound effects confirmed by no-speech → keep classification. SDH with speech detected → reclassify to `.dialogue` (incidental brackets in dialogue).

### Phase 2: Audio Track Selection

ffprobe audio streams are already available from `FFprobeMediaInspectionService`. Present candidates to user with auto-select defaults:

1. **Language match**: prefer track matching source subtitle language
2. **Codec preference** (same language): `AC3 < E-AC3 < AAC < DTS < TrueHD < DTS-HD MA` — smaller codecs minimize extraction cost and processing time
3. **Channel extraction**: center channel for 5.1/7.1, mono downmix for stereo
4. **Sample rate**: always resample to 16kHz for VAD (reduces data ~90x vs 48kHz stereo)

Extraction per VAD region:
```
ffmpeg -ss <start - 2s> -i <video> -t <duration + 4s> \
  -map 0:a:<stream_index> -af "<pan_filter>" \
  -ar 16000 -ac 1 -f wav pipe:1
```

### Phase 3: Stratified VAD Sampling

To minimize LAN I/O for large remote files (80+ GB):

1. **Merge temporal ranges**: collect all `.dialogue` cue time ranges from both subtitles. Merge adjacent ranges with gap ≤ 3 seconds. Add 2s padding on each side.
2. **Extract audio**: for each merged range, run ffmpeg with `-ss` seek (keyframe-precise for speed over LAN). Pipe to stdout — no temp files.
3. **Run Silero VAD**: process each audio clip through ONNX model. Output: list of `[start_ms, end_ms, confidence]` speech segments relative to video timeline.
4. **Parallelize**: extract and process multiple non-overlapping ranges concurrently.

### Phase 4: Per-Cue VAD Scoring

For each cue in each subtitle, compute alignment to VAD speech segments:

```
cueVADScore = overlap(cue_time, nearest_speech_segment) / cue_duration
```

- Fully inside speech segment → 1.0 (perfect match)
- Partial overlap → proportional score
- Zero overlap → 0.0 (SDH, ad, or error)

Also compute boundary deltas: `cue.start - speech.start`, `cue.end - speech.end`.

### Phase 5: Piecewise Arbitration

For each aligned cue pair (source + target matched by DP):

```
if source.cueVADScore > target.cueVADScore + 0.15:
    master = source
elif target.cueVADScore > source.cueVADScore + 0.15:
    master = target
else:
    master = whichever has higher document-level average VAD score
```

The master can switch mid-video — a different subtitle can be master for scene 1 vs scene 3.

Unmatched cues (skipSource/skipTarget):
- `cueVADScore > 0.7` → keep (real content other subtitle missed)
- Otherwise → drop or flag

### Phase 6: Feed into Existing Pipeline

Inject VAD-weighted confidence into `SubtitleAligner.pairConfidence()`:

```swift
// New term (weight ~0.25):
let vadAgreement = 1.0 - abs(source.cueVADScore - target.cueVADScore)
```

`SubtitleMergeService.buildTimelineCues()` uses the piecewise master to determine which side's boundaries to snap to (instead of always using source).

## VAD Engine: Silero VAD

| Property | Value |
|----------|-------|
| Model | `silero_vad.onnx` (1.5 MB) |
| Inference | ONNX Runtime |
| Speed | ~50x real-time on CPU |
| Language | Language-agnostic (works with any audio) |
| Output | Speech segments with start/end timestamps |

Bundled in `SubtitleStudio/Tools/silero_vad.onnx`, same as existing media tools. ONNX Runtime is available on macOS via Swift-compatible C bindings.

Alternative considered and rejected: ffmpeg `silencedetect` — too inaccurate for movie audio (confuses speech with music/sound effects). WebRTC VAD — frame-level only, poor accuracy on diverse audio.

## Files Changed

| File | Change |
|------|--------|
| `SubtitleStudio/Domain/Models.swift` | Add `CueKind` enum, `cueVADScore` field, `VADArbitrationResult` struct |
| `SubtitleStudio/Services/ServiceProtocols.swift` | Add `VADServicing` protocol |
| `SubtitleStudio/Services/SubtitleAlignmentService.swift` | Add VAD-weighted term to `pairConfidence()`; accept optional `VADArbitrationResult` |
| `SubtitleStudio/Services/SubtitleMergeService.swift` | Accept `VADArbitrationResult`; use piecewise master in `buildTimelineCues()` |
| `SubtitleStudio/App/AppEnvironment.swift` | Wire `SileroVADService` into `.live` |
| `SubtitleStudio/ViewModels/WorkflowViewModel.swift` | Add audio track selection UI state; trigger VAD analysis gate |
| **New** `SubtitleStudio/Infrastructure/Media/SileroVADService.swift` | VAD implementation: ONNX inference, audio extraction, cue scoring |
| **New** `SubtitleStudio/Tools/silero_vad.onnx` | Bundled model (~1.5 MB) |
| `SubtitleStudio/Views/WorkflowInspectorView.swift` | Audio track picker UI; VAD analysis trigger button |

## Verification

- Build: existing `xcodegen generate && xcodebuild ... build`
- Unit test: mock VAD service returning known speech segments → verify piecewise arbitration output
- Integration: sample 5 video + subtitle pairs with known misalignment → verify `matchedCueRatio` improves after VAD analysis
- Performance: on 80GB LAN file, VAD analysis should complete in < 30 seconds (stratified sampling, ~5–15 audio regions)
