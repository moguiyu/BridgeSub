import Foundation

struct SubtitleInventoryService: SubtitleInventoryServicing {
    func buildInventory(from report: VideoInspectionReport) -> SubtitleInventory {
        let isLargeRemoteMKV = RemoteMediaPolicy.isLargeRemoteMKV(report.videoURL)
        let skippedBitmapTracks = report.embeddedSubtitleTracks.filter { !$0.isTextBased && $0.resolvedLanguage != nil }
        let bitmapTrackCounts = Dictionary(
            grouping: skippedBitmapTracks,
            by: \.resolvedLanguage
        )
        .reduce(into: [LanguageOption: Int]()) { partialResult, entry in
            guard let language = entry.key else { return }
            partialResult[language] = entry.value.count
        }
        let embeddedCandidates = report.embeddedSubtitleTracks.compactMap { track -> SubtitleCandidate? in
            guard let language = track.resolvedLanguage else { return nil }
            guard track.isTextBased else { return nil }
            return SubtitleCandidate(
                id: "embedded-\(track.index)",
                language: language,
                format: .vtt,
                origin: .embedded,
                sourceLabel: track.displayLabel,
                availability: .available,
                loadState: .unloaded,
                locator: .embedded(trackIndex: track.index),
                rankingScore: rankEmbedded(track, isLargeRemoteMKV: isLargeRemoteMKV),
                fileURL: nil,
                embeddedTrack: track
            )
        }

        let sidecarCandidates = report.localSubtitleSidecars.compactMap { url -> SubtitleCandidate? in
            let language = inferLanguage(from: url)
            let format = SubtitleFormatKind(rawValue: url.pathExtension.lowercased()) ?? .unknown
            return SubtitleCandidate(
                id: "sidecar-\(url.lastPathComponent)",
                language: language ?? .english, // Default to English if not detected; user can still select it
                format: format,
                origin: .localFile,
                sourceLabel: url.lastPathComponent,
                availability: .available,
                loadState: .unloaded,
                locator: .file(url),
                rankingScore: rankSidecar(url),
                fileURL: url,
                embeddedTrack: nil
            )
        }

        var warnings = report.warnings
        if !skippedBitmapTracks.isEmpty {
            warnings.append(
                "Skipped \(skippedBitmapTracks.count) image-based embedded subtitle tracks (for example PGS/VobSub). OCR is not implemented yet."
            )
        }
        if isLargeRemoteMKV, embeddedCandidates.contains(where: { $0.origin == .embedded }) {
            warnings.append(
                "Embedded subtitles in large MKV files on mounted volumes may require scanning the full remote file. Search/download or sidecar subtitles are recommended."
            )
        }

        return SubtitleInventory(
            videoURL: report.videoURL,
            containerName: report.containerName,
            candidates: embeddedCandidates + sidecarCandidates,
            bitmapTrackCounts: bitmapTrackCounts,
            warnings: warnings
        )
    }

    private func inferLanguage(from url: URL) -> LanguageOption? {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let tokens = stem
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map(String.init)

        for token in tokens.reversed() {
            if let language = LanguageOption.resolve(from: token) {
                return language
            }
        }

        return nil
    }

    private func rankEmbedded(_ track: EmbeddedSubtitleTrack, isLargeRemoteMKV: Bool) -> Double {
        if isLargeRemoteMKV {
            return 0.25
        }

        var score = 1.0
        if track.disposition?.contains("default") == true {
            score += 0.3
        }
        if let title = track.title?.lowercased(), title.contains("full") {
            score += 0.1
        }
        if track.codecName.lowercased().contains("ass") {
            score += 0.05
        }
        return score
    }

    private func rankSidecar(_ url: URL) -> Double {
        var score = 0.8
        let name = url.lastPathComponent.lowercased()
        if name.contains("forced") {
            score -= 0.2
        }
        if name.contains("sdh") || name.contains("hi") {
            score -= 0.1
        }
        if url.pathExtension.lowercased() == "ass" {
            score += 0.05
        }
        return score
    }
}
