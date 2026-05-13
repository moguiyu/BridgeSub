# Translation UI Renovation — Design

## Summary

Redesign Settings and Workspace UI for the new translation algorithm. Remove
misleading/dead controls, surface context-window awareness, simplify to a minimal
user-facing surface with AI-driven defaults. Out of scope: the set of supported
target languages, provider auth/key UI, MKV export controls.

## Settings — Translation Tab

### Simple View (default)

**Content Type** picker (replaces `translationQualityProfile` + `TranslationStrictness`):

| Type | What the LLM is told |
|------|---------------------|
| Drama/General | Natural tone, balanced fidelity, standard speed. Best for most film/TV. |
| Comedy | Protect punchlines, irony, timing. Creative adaptation of wordplay allowed. |
| Action/Thriller | Terse, punchy. Short cues for fast cuts. Slang and tension intact. |
| Documentary | Formal register. Speaker titles preserved. Precision over style. |
| Children's | Short sentences, simple vocabulary, slower reading speed. |

Each Content Type maps to a distinct prompt delta block; if two presets cannot
produce a measurably different prompt they MUST be collapsed before ship.

**Instructions** (per-card free text, replaces `TranslateState.episodeContext`)
with template picker:

- None / Preserve Historical Terms / Adapt Humor Culturally / Short-Form /
  Singable/Musical / Custom

Per-card placement matches the per-job nature of episode/scene context. A global
"baseline" Instructions field is NOT added.

### Advanced (folded, hidden by default)

- **Pass Strategy** — picker matching `PassStrategy` enum cases verbatim
  (`bestQuality` / `reviewAndRewrite` / `draftOnly`, labelled in UI). ⓘ explains
  cost/quality trade-off.
- **Reference Override Confidence** slider — already exists as
  `ProviderSettings.referenceOverrideConfidenceThreshold` (default at
  `Models.swift:1962`). Range 0.0–1.0, default 0.75. Gates whether an aligned
  reference cue overrides a draft translation. ⓘ explains effect.
- **Single-Pass Mode** (Auto / Force / Off) — promoted from per-card to global
  default. The per-card `TranslateState.singlePassPreference` at
  `Models.swift:734` is REMOVED; its accessors at
  `WorkflowViewModel.swift:627-633` are deleted. Loss of per-card override is
  intentional; user can flip globally before each translate if needed.
- **Temperature** (0.1–0.3 clamp) — ⓘ explained.

### Removed from Settings

| Field | Reason | Code touch |
|---|---|---|
| `translationKeepNames` / `KeepLocations` / `KeepBrands` toggles | Replaced by always-on hard rule in system prompt. Requires deleting conditional prompt clause at `TranslationOrchestrator.swift:621-623` AND removing the three params from the `TranslationConfiguration` struct (lines 17-19, 40-42, 62-64, 86-88). The replacement system-prompt language is added in the same change so behavior is preserved, not silently dropped. |
| `TranslationStrictness` picker | Folded into Content Type. |
| `translationBatchSize` stepper + textfield | Auto-calculated from context window — see Context Budget Bar below. |
| Legacy `ProviderSettings` fields (`selectedProvider`, `ollamaBaseURL`, etc.) | Dead shim, no readers. |

### Settings migration

`ProviderSettings.load(from:)` (`Models.swift:1926`) currently reads each
removed key from `UserDefaults`. Migration policy:

- Drop the reads. Do NOT write the old keys back.
- Add a one-shot defaults cleanup that removes the obsolete keys
  (`translationQualityProfile`, `translationStrictness`, `translationKeepNames`,
  `translationKeepLocations`, `translationKeepBrands`, `translationBatchSize`)
  on first launch of the new build, gated by a `settingsSchemaVersion` int key
  bumped to `2`.
- Old `translationQualityProfile` values are NOT migrated to Content Type — the
  semantics differ enough that a clean default is preferable. Note in release
  notes.

## Workspace — Translation Panel

### Layout

```
[Target Language Picker]        ← relocate existing, do not re-add
[Source Subtitles selector + alignment status + explanation]
[Reference Subtitles selector + alignment status + explanation] (optional)
[Context Budget Bar + single-pass eligibility]
[Instructions field (per-card)]
[Translate Button]
[Last Run Summary]
```

### Target language picker — relocate, not add

The picker already exists at `SubtitleWorkspaceView.swift:578-595`, bound to
`viewModel.cards[cardIndex].language`. This plan keeps that binding and only
moves the picker into the new panel header. The earlier draft's claim that the
target was "hardcoded to zh-Hans" was incorrect (zh-Hans is only the *default*
at `Models.swift:1323`); the picker itself stays.

### Pre-alignment pipelines (different per source vs reference)

- **Source ↔ video timeline**: VAD drift correction (existing). Audio-based.
- **Reference ↔ source**: Needleman–Wunsch text alignment only via
  `SubtitleAligner`. No VAD (reference has no associated audio track in the
  current pipeline).

Both surfaces show alignment confidence and offset inline. The
`PreAlignmentState` enum at `Models.swift:720` already models this; UI binds to
`TranslateState.preAlignmentState` and `preAlignmentSummary` (lines 748-749).

### Context Budget Bar

Shows prompt size vs the active provider/model's context window. Data sources:

- Provider context-window limit: lookup table keyed by `(presetID, model)`
  maintained alongside `TranslationProviderPresetID` in `Models.swift`.
  Unknown models fall back to the smallest plausible window (4k) with a "?"
  badge.
- Prompt size estimate: char-count heuristic
  (`promptCharacters / charsPerToken[providerFamily]`), NOT a real tokenizer —
  shipping a tokenizer per provider is out of scope. The bar is labelled as an
  estimate.
- Single-pass eligibility: derived from `(estimatedPromptTokens + cueBudget) <
  contextWindow * 0.8`. Surfaced as a badge next to the bar.

Auto batch-size is `floor((contextWindow * 0.6 - systemPromptTokens) /
avgCueTokens)`, clamped to `[10, 200]`.

### Removed from Workspace

- Provider picker → moved to Settings.
- Single-pass picker → moved to Advanced Settings (see scope change above).
- Episode context field → replaced by per-card Instructions; field renamed at
  the call site (`WorkflowViewModel.swift:1635`, struct at `Models.swift:735`
  and `Models.swift:640-661`).
- Cultural Anchor as a separate concept → reference subtitle serves this role.
- Dead state on `WorkflowViewModel`: `spotCheckEnabled`, `spotCheckSampleSize`,
  `selectedProcessingOption` (lines 56-58), `validateProviderConfiguration`.
  Verify no readers remain before deletion.

## Files

| Action | File | What changes |
|---|---|---|
| Edit | `SubtitleStudio/Views/SettingsView.swift` | Add Content Type picker; fold/hide Advanced section; delete keep* toggles, strictness picker, batch-size controls. |
| Edit | `SubtitleStudio/Views/SubtitleWorkspaceView.swift` | New translation panel layout; relocate `languagePicker`; add Context Budget Bar view; add per-card Instructions field; delete provider picker. |
| Edit | `SubtitleStudio/Views/WorkflowInspectorView.swift` | Remove inspector duplicates of relocated controls (audit only — confirm scope before editing). |
| Edit | `SubtitleStudio/ViewModels/WorkflowViewModel.swift` | Drop `spotCheck*`, `selectedProcessingOption`; rename `episodeContext` plumbing → `instructions`; remove per-card `singlePassPreference` accessors at 627-633; update orchestrator call at 1635-1651. |
| Edit | `SubtitleStudio/Domain/Models.swift` | `ProviderSettings`: add `contentType`, drop `translationStrictness`/`translationKeepNames`/`KeepLocations`/`KeepBrands`/`translationBatchSize`/`translationQualityProfile`; add `settingsSchemaVersion`. `TranslateState`: rename `episodeContext` → `instructions`, drop `singlePassPreference`. Add provider/model → context-window lookup. |
| Edit | `SubtitleStudio/Services/TranslationOrchestrator.swift` | Remove `keepNames/Locations/Brands` from `TranslationConfiguration` (lines 17-19, 40-42, 62-64, 86-88); delete conditional prompt block at 621-623; replace with always-on preservation language in the system prompt. Accept `ContentType` instead of `qualityProfile`/`strictness`. |

## Verification

- `xcodegen generate && xcodebuild -project SubtitleStudio.xcodeproj -scheme SubtitleStudio -destination 'platform=macOS' build`
- Manual: translate one card without a reference; one card with a reference; one
  card with an Instructions template applied. Confirm:
  - Pre-alignment summaries render for source (VAD) and reference (NW) paths.
  - Context Budget Bar updates when switching provider/model in Settings.
  - Single-pass eligibility badge flips at the predicted cue count.
  - First launch on a profile with old `UserDefaults` keys: app starts cleanly,
    obsolete keys gone after one app run.

## Risk register

| Risk | Mitigation |
|---|---|
| Removing `keep*` toggles drops prompt behavior silently | Update orchestrator system prompt in the same change; spot-check translated output for names/locations before merging. |
| Context Budget Bar misleads users (char-count vs real tokens) | Label as estimate; conservative 0.6/0.8 thresholds; "?" badge for unknown models. |
| Lost per-card single-pass override | Document in release notes; revisit if user feedback complains. |
| Stale UserDefaults keys persist on machines that skip the migration version bump | One-shot cleanup is idempotent; safe to re-run on future schema bumps. |
