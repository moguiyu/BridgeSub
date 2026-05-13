import Foundation
import OSLog

struct TranslationLogger {
    private let logger = Logger(
        subsystem: "com.moguiyu.BridgeSub",
        category: "Translation"
    )

    func translationStarted(provider: String, model: String, totalCues: Int, from: String, to: String) {
        logger.info("Translation started: provider=\(provider, privacy: .public) model=\(model, privacy: .public) cues=\(totalCues) from=\(from, privacy: .public) to=\(to, privacy: .public)")
    }

    func batchStarted(range: String, cueCount: Int, passKind: String) {
        logger.debug("Batch started: range=\(range, privacy: .public) cues=\(cueCount) pass=\(passKind, privacy: .public)")
    }

    func batchCompleted(range: String, duration: Duration, cuesTranslated: Int, passStrategy: String) {
        let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000
            + Double(duration.components.seconds) * 1000
        logger.info("Batch completed: range=\(range, privacy: .public) cues=\(cuesTranslated) latency=\(String(format: "%.0f", ms))ms strategy=\(passStrategy, privacy: .public)")
    }

    func retryAttempt(_ n: Int, reason: String, strategy: String) {
        logger.notice("Retry #\(n): reason=\(reason, privacy: .public) strategy=\(strategy, privacy: .public)")
    }

    func batchFailed(range: String, error: String) {
        logger.error("Batch failed: range=\(range, privacy: .public) error=\(error, privacy: .public)")
    }

    func translationCompleted(totalCues: Int, duration: Duration, batches: Int, retries: Int) {
        let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000
            + Double(duration.components.seconds) * 1000
        logger.info("Translation completed: cues=\(totalCues) latency=\(String(format: "%.0f", ms))ms batches=\(batches) retries=\(retries)")
    }

    func translationCancelled(reason: String) {
        logger.info("Translation cancelled: reason=\(reason, privacy: .public)")
    }

    func configurationInvalid(reason: String) {
        logger.error("Configuration invalid: \(reason, privacy: .public)")
    }

    func configurationValidated(provider: String, model: String) {
        logger.debug("Configuration validated: provider=\(provider, privacy: .public) model=\(model, privacy: .public)")
    }
}
