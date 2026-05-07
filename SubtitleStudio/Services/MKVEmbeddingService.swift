import Foundation

struct MKVEmbeddingService: MKVEmbeddingServicing {
    private let processRunner: ProcessRunner
    private let exportService: SubtitleExportServicing
    private let toolRegistry: MediaToolRegistry

    init(
        processRunner: ProcessRunner,
        exportService: SubtitleExportServicing,
        toolRegistry: MediaToolRegistry
    ) {
        self.processRunner = processRunner
        self.exportService = exportService
        self.toolRegistry = toolRegistry
    }

    func embedCapability(
        for inspectionReport: VideoInspectionReport,
        merged: MergedSubtitleDocument,
        destinationMode: EmbedDestinationMode
    ) -> EmbeddedExportCapability {
        let profile = ContainerEmbeddingProfile.resolve(from: inspectionReport)
        guard profile.family != .unsupported else {
            let ext = inspectionReport.videoURL.pathExtension.lowercased()
            let containerLabel = ext.isEmpty ? inspectionReport.containerName : ext.uppercased()
            return EmbeddedExportCapability(
                isAvailable: false,
                plan: nil,
                message: "Embedded export is not supported for \(containerLabel) in this milestone."
            )
        }

        guard let backend = preferredBackend(for: profile) else {
            return EmbeddedExportCapability(
                isAvailable: false,
                plan: nil,
                message: "No supported embedded export backend is available."
            )
        }

        guard let plan = profile.plan(for: merged, backend: backend) else {
            return EmbeddedExportCapability(
                isAvailable: false,
                plan: nil,
                message: "Embedded export is not supported for \(profile.preferredOutputExtension.uppercased()) in this milestone."
            )
        }

        let message = capabilityMessage(for: plan, destinationMode: destinationMode)
        return EmbeddedExportCapability(
            isAvailable: true,
            plan: plan,
            message: message
        )
    }

    func embed(
        merged: MergedSubtitleDocument,
        inspectionReport: VideoInspectionReport,
        destinationMode: EmbedDestinationMode
    ) async throws -> URL {
        let capability = embedCapability(
            for: inspectionReport,
            merged: merged,
            destinationMode: destinationMode
        )
        guard capability.isAvailable, let plan = capability.plan else {
            throw WorkflowError.unsupported(capability.message)
        }

        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let exportDocument = MergedSubtitleDocument(
            sourceLanguage: merged.sourceLanguage,
            targetLanguage: merged.targetLanguage,
            outputFormat: plan.subtitleFormat,
            cues: merged.cues,
            alignmentReport: merged.alignmentReport
        )
        let sidecarURL = tempDirectory.appendingPathComponent("merged.\(plan.subtitleFormat.fileExtension)")
        try exportService.export(exportDocument, to: sidecarURL)

        let workingOutputURL = embedOutputURL(
            for: inspectionReport.videoURL,
            merged: merged,
            outputExtension: plan.outputExtension,
            destinationMode: destinationMode
        )
        do {
            switch plan.backend {
            case .ffmpeg:
                guard let ffmpeg = toolRegistry.executablePath(for: .ffmpeg) else {
                    throw WorkflowError.dependencyUnavailable("`ffmpeg` is not installed.")
                }

                _ = try await processRunner.run(
                    executable: ffmpeg,
                    arguments: makeFFmpegArguments(
                        videoURL: inspectionReport.videoURL,
                        sidecarURL: sidecarURL,
                        destinationURL: workingOutputURL,
                        plan: plan,
                        existingSubtitleTrackCount: inspectionReport.embeddedSubtitleTracks.count,
                        merged: merged
                    )
                )
            case .mkvmerge:
                guard let mkvmerge = toolRegistry.executablePath(for: .mkvmerge) else {
                    throw WorkflowError.dependencyUnavailable("`mkvmerge` is not installed.")
                }

                _ = try await processRunner.run(
                    executable: mkvmerge,
                    arguments: makeMKVMergeArguments(
                        videoURL: inspectionReport.videoURL,
                        sidecarURL: sidecarURL,
                        destinationURL: workingOutputURL,
                        merged: merged
                    )
                )
            }
        } catch {
            throw WorkflowError.runtime(userFacingEmbedError(from: error, capability: capability))
        }

        return try finalizeEmbeddedOutput(
            tempOutputURL: workingOutputURL,
            originalVideoURL: inspectionReport.videoURL,
            destinationMode: destinationMode
        )
    }

    func embedOutputURL(
        for videoURL: URL,
        merged: MergedSubtitleDocument,
        outputExtension: String,
        destinationMode: EmbedDestinationMode
    ) -> URL {
        switch destinationMode {
        case .createNewFile:
            return uniqueOutputURL(
                base: merged.defaultEmbeddedOutputURL(
                    for: videoURL,
                    outputExtension: outputExtension
                )
            )
        case .replaceOriginal:
            return replacementTempOutputURL(for: videoURL, outputExtension: outputExtension)
        }
    }

    func finalizeEmbeddedOutput(
        tempOutputURL: URL,
        originalVideoURL: URL,
        destinationMode: EmbedDestinationMode
    ) throws -> URL {
        switch destinationMode {
        case .createNewFile:
            return tempOutputURL
        case .replaceOriginal:
            return try replaceOriginalVideo(with: tempOutputURL, originalVideoURL: originalVideoURL)
        }
    }

    private func uniqueOutputURL(base: URL) -> URL {
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let directory = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension

        for index in 1...99 {
            let candidate = directory.appendingPathComponent("\(stem)-\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(6)).\(ext)")
    }

    private func replacementTempOutputURL(for videoURL: URL, outputExtension: String) -> URL {
        let directory = videoURL.deletingLastPathComponent()
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let ext = outputExtension.isEmpty ? videoURL.pathExtension.lowercased() : outputExtension
        let normalizedExtension = ext.isEmpty ? "mkv" : ext
        return directory.appendingPathComponent(".\(stem).embed-\(UUID().uuidString).\(normalizedExtension)")
    }

    private func replaceOriginalVideo(with tempOutputURL: URL, originalVideoURL: URL) throws -> URL {
        let backupURL = originalVideoURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(originalVideoURL.lastPathComponent).backup-\(UUID().uuidString)")

        var backupExists = false
        defer {
            // Always attempt to clean up backup file on failure
            if backupExists || FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
            }
        }

        do {
            try FileManager.default.moveItem(at: originalVideoURL, to: backupURL)
            backupExists = true
        } catch {
            throw replacementFailure(tempOutputURL: tempOutputURL, message: error.localizedDescription)
        }

        do {
            try FileManager.default.moveItem(at: tempOutputURL, to: originalVideoURL)
        } catch {
            // Attempt to restore original
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.moveItem(at: backupURL, to: originalVideoURL)
            }
            backupExists = false  // Prevent defer from trying to delete
            throw replacementFailure(
                tempOutputURL: tempOutputURL,
                message: "The original video was restored. \(error.localizedDescription)"
            )
        }

        backupExists = false  // Success - prevent defer from trying to delete
        return originalVideoURL
    }

    private func replacementFailure(tempOutputURL: URL, message: String) -> WorkflowError {
        WorkflowError.runtime(
            "Embedded subtitles were written to \(tempOutputURL.path), but replacing the original video failed. \(message)"
        )
    }

    func makeFFmpegArguments(
        videoURL: URL,
        sidecarURL: URL,
        destinationURL: URL,
        plan: EmbeddedExportPlan,
        existingSubtitleTrackCount: Int,
        merged: MergedSubtitleDocument
    ) -> [String] {
        let streamIndex = existingSubtitleTrackCount
        let title = "\(merged.sourceLanguage.displayName) + \(merged.targetLanguage.displayName)"

        return [
            "-y",
            "-i", videoURL.path,
            "-i", sidecarURL.path,
            "-map", "0",
            "-map", "1:0",
            "-c", "copy",
            "-c:s:\(streamIndex)", plan.subtitleCodec,
            "-metadata:s:s:\(streamIndex)", "title=\(title)",
            destinationURL.path
        ]
    }

    private func capabilityMessage(for plan: EmbeddedExportPlan, destinationMode: EmbedDestinationMode) -> String {
        let backendStatus = toolRegistry.status(for: plan.backend.tool)
        let operationText: String
        switch destinationMode {
        case .createNewFile:
            operationText = "Embedding will create a new \(plan.outputExtension.uppercased()) file beside the video."
        case .replaceOriginal:
            operationText = "Embedding will replace the original \(plan.outputExtension.uppercased()) file after a successful remux."
        }

        let backendText = "Using \(backendStatus.summaryLabel)."
        return [plan.compatibilityNote, backendText, operationText]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func userFacingEmbedError(from error: Error, capability: EmbeddedExportCapability) -> String {
        let rawMessage: String
        if case WorkflowError.runtime(let message) = error {
            rawMessage = message
        } else {
            rawMessage = error.localizedDescription
        }

        let summary = sanitizeFFmpegOutput(rawMessage)
        if summary.isEmpty {
            return capability.message
        }
        return "\(capability.message) \(summary)"
    }

    private func sanitizeFFmpegOutput(_ output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let filtered = lines.filter { line in
            let lowered = line.lowercased()
            return !lowered.hasPrefix("ffmpeg version")
                && !lowered.hasPrefix("mkvmerge v")
                && !lowered.hasPrefix("built with")
                && !lowered.hasPrefix("configuration:")
                && !lowered.hasPrefix("libav")
        }

        let prioritized = filtered.last { line in
            let lowered = line.lowercased()
            return lowered.contains("error")
                || lowered.contains("invalid")
                || lowered.contains("unsupported")
                || lowered.contains("could not")
                || lowered.contains("failed")
        }

        if let prioritized {
            return prioritized
        }

        return filtered.suffix(2).joined(separator: " ")
    }

    func makeMKVMergeArguments(
        videoURL: URL,
        sidecarURL: URL,
        destinationURL: URL,
        merged: MergedSubtitleDocument
    ) -> [String] {
        let title = "\(merged.sourceLanguage.displayName) + \(merged.targetLanguage.displayName)"

        return [
            "-o", destinationURL.path,
            videoURL.path,
            "--language", "0:und",
            "--track-name", "0:\(title)",
            sidecarURL.path
        ]
    }

    private func preferredBackend(for profile: ContainerEmbeddingProfile) -> EmbeddedExportBackendKind? {
        switch profile.family {
        case .matroska:
            if toolRegistry.executablePath(for: .mkvmerge) != nil {
                return .mkvmerge
            }
            if toolRegistry.executablePath(for: .ffmpeg) != nil {
                return .ffmpeg
            }
            return nil
        case .webm:
            return toolRegistry.executablePath(for: .ffmpeg) == nil ? nil : .ffmpeg
        case .unsupported:
            return nil
        }
    }
}
