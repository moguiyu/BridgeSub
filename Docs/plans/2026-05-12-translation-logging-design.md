# Translation Pipeline Logging Design

## Motivation

Translation code (`TranslationOrchestrator`, `TranslationProviders`) currently produces zero log output. Errors are thrown as `WorkflowError` and caught by the view model, but with no structured trace of what happened, when, or with what inputs. Two other services use `Logger` with inconsistent subsystem names (`com.xiaodong.SubtitleStudio` vs `com.xiaodong.BridgeSub`). This makes ongoing observability impossible.

## Design

### Approach: Lightweight `TranslationLogger` utility

A small struct wrapping `Logger` with translation-specific helpers. No protocol/service abstraction — that would be overkill for key-events-only logging.

```swift
// SubtitleStudio/Infrastructure/Translation/TranslationLogger.swift
import OSLog

struct TranslationLogger {
    private let logger = Logger(
        subsystem: "com.xiaodong.SubtitleStudio",
        category: "Translation"
    )

    func translationStarted(provider: String, model: String, totalCues: Int, from: String, to: String)
    func batchStarted(range: String, cueCount: Int, passKind: String)
    func batchCompleted(range: String, latency: Duration, cuesTranslated: Int, passStrategy: String)
    func retryAttempt(_ n: Int, reason: String, strategy: String)
    func batchFailed(range: String, error: Error)
    func translationCompleted(totalCues: Int, totalLatency: Duration, batches: Int, retries: Int)
    func translationCancelled()
    func configurationInvalid(reason: String)
    func configurationValidated(provider: String, model: String)
}
```

### Logged Events

| Event | Level | When |
|-------|-------|------|
| Translation started | `.info` | Orchestrator begins: provider, model, total cues, language pair |
| Batch started | `.debug` | Each batch: range, cue count, pass kind |
| Batch completed | `.info` | Each batch: latency, cues translated, pass strategy |
| Retry | `.notice` | Retry triggered: reason (parse/validation/network), strategy (shorter/halved) |
| Batch failed | `.error` | Batch exhausted retries: error details |
| Translation completed | `.info` | Final outcome: total cues, time, batch count, retry count |
| Translation cancelled | `.info` | User cancelled mid-translation |
| Configuration invalid | `.error` | Provider config check failed (missing key, bad URL) |

### What is NOT logged

- Individual cue translations (noisy)
- Prompt full text (contains PII, too verbose)
- Raw API response bodies (clutters Console.app)
- Internal validation details (line counts, character counts)

### Subsystem Consistency Fix

`SileroVADService` currently uses `com.xiaodong.BridgeSub` — unified to `com.xiaodong.SubtitleStudio` for consistent Console.app filtering.

## Files

| Action | File |
|--------|------|
| **New** | `SubtitleStudio/Infrastructure/Translation/TranslationLogger.swift` |
| **Edit** | `SubtitleStudio/Services/TranslationOrchestrator.swift` |
| **Edit** | `SubtitleStudio/Infrastructure/Translation/TranslationProviders.swift` |
| **Edit** | `SubtitleStudio/Infrastructure/Media/SileroVADService.swift` |

## Access

All logs Viewable via:
- **Console.app**: filter by subsystem `com.xiaodong.SubtitleStudio` and category `Translation`
- **Terminal**: `log stream --predicate 'subsystem == "com.xiaodong.SubtitleStudio" AND category == "Translation"' --level debug`
