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
                embeddedTrack: track,
                kind: classifyCandidateKind(label: track.displayLabel)
            )
        }

        let sidecarURLs = discoverSidecarFiles(from: report.videoURL)
        let sidecarCandidates = sidecarURLs.compactMap { url -> SubtitleCandidate? in
            let language = inferLanguage(from: url)
            let format = SubtitleFormatKind(rawValue: url.pathExtension.lowercased()) ?? .unknown
            let videoDir = report.videoURL.deletingLastPathComponent()
            let relativePath = url.path.hasPrefix(videoDir.path)
                ? String(url.path.dropFirst(videoDir.path.count + 1))
                : url.lastPathComponent
            let kind = classifyCandidateKind(label: url.lastPathComponent)
            return SubtitleCandidate(
                id: "sidecar-\(url.lastPathComponent)",
                language: language ?? .english,
                format: format,
                origin: .localFile,
                sourceLabel: url.lastPathComponent,
                availability: .available,
                loadState: .unloaded,
                locator: .file(url),
                rankingScore: rankSidecar(url),
                fileURL: url,
                embeddedTrack: nil,
                kind: kind,
                relativePath: relativePath
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

    private func discoverSidecarFiles(
        from videoURL: URL,
        supportedExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]
    ) -> [URL] {
        let videoDir = videoURL.deletingLastPathComponent()
        let videoStem = videoURL.deletingPathExtension().lastPathComponent
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: videoDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [(url: URL, matchQuality: Int, depth: Int)] = []
        let standardizedVideoDir = videoDir.standardized

        for case let fileURL as URL in enumerator {
            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let stem = fileURL.deletingPathExtension().lastPathComponent
            let isSameDir = fileURL.deletingLastPathComponent().standardized == standardizedVideoDir
            let hasStemMatch = stem.localizedCaseInsensitiveContains(videoStem)
            let depth = fileURL.pathComponents.count - videoDir.pathComponents.count
            let matchQuality: Int
            switch (isSameDir, hasStemMatch) {
            case (true, true):  matchQuality = 3
            case (true, false): matchQuality = 2
            case (false, true): matchQuality = 1
            case (false, false): matchQuality = 0
            }
            found.append((fileURL, matchQuality, depth))
        }

        found.sort {
            if $0.matchQuality != $1.matchQuality { return $0.matchQuality > $1.matchQuality }
            return $0.depth < $1.depth
        }
        return found.map(\.url)
    }

    private func classifyCandidateKind(label: String) -> CueKind {
        let lower = label.lowercased()
        if lower.contains("forced") || lower.contains(" fn") || lower.hasSuffix(".fn") {
            return .forcedNarrative
        }
        if lower.contains("sdh") || lower.contains("hearing impaired")
            || lower.contains("closed caption") || lower.contains("[cc]") {
            return .sdh
        }
        if lower.contains("audio description") || lower.contains(" ad.") || lower.hasSuffix(".ad") {
            return .ad
        }
        return .unknown
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
