import Foundation

struct FFprobeMediaInspectionService: MediaInspectionServicing {
    private let processRunner: ProcessRunner
    private let toolRegistry: MediaToolRegistry

    init(processRunner: ProcessRunner, toolRegistry: MediaToolRegistry) {
        self.processRunner = processRunner
        self.toolRegistry = toolRegistry
    }

    func inspect(videoURL: URL) async throws -> VideoInspectionReport {
        guard let executable = toolRegistry.executablePath(for: .ffprobe) else {
            return VideoInspectionReport(
                videoURL: videoURL,
                containerName: videoURL.pathExtension.lowercased(),
                embeddedSubtitleTracks: [],
                audioStreams: [],
                localSubtitleSidecars: findSidecars(near: videoURL),
                warnings: ["`ffprobe` was not found. Embedded subtitle and audio inspection is disabled."]
            )
        }
        let data = try await processRunner.run(
            executable: executable,
            arguments: [
                "-v", "quiet",
                "-print_format", "json",
                "-show_entries", "format=format_name:stream=index,codec_name,codec_type,channels,bit_rate:stream_tags=language,title:stream_disposition=default,forced",
                videoURL.path
            ]
        )

        let payload = try JSONDecoder().decode(FFprobePayload.self, from: data)
        let subtitleTracks = payload.streams
            .filter { $0.codecType == "subtitle" }
            .enumerated()
            .map { offset, stream in
                EmbeddedSubtitleTrack(
                    id: offset,
                    index: stream.index,
                    codecName: stream.codecName ?? "unknown",
                    languageCode: stream.tags?.language,
                    resolvedLanguage: LanguageOption.resolve(from: stream.tags?.language),
                    title: stream.tags?.title,
                    disposition: stream.disposition?.description
                )
            }

        let audioTracks = payload.streams
            .filter { $0.codecType == "audio" }
            .enumerated()
            .map { offset, stream in
                AudioStream(
                    id: offset,
                    index: stream.index,
                    codecName: stream.codecName ?? "unknown",
                    languageCode: stream.tags?.language,
                    resolvedLanguage: LanguageOption.resolve(from: stream.tags?.language),
                    channels: stream.channels ?? 0,
                    bitrate: stream.bitRate.flatMap { Int($0) }
                )
            }

        return VideoInspectionReport(
            videoURL: videoURL,
            containerName: payload.format?.formatName ?? videoURL.pathExtension.lowercased(),
            embeddedSubtitleTracks: subtitleTracks,
            audioStreams: audioTracks,
            localSubtitleSidecars: findSidecars(near: videoURL),
            warnings: []
        )
    }

    private func findSidecars(near videoURL: URL) -> [URL] {
        guard let directory = try? FileManager.default.contentsOfDirectory(
            at: videoURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let stem = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        return directory
            .filter { ["srt", "ass", "vtt", "ssa", "sub"].contains($0.pathExtension.lowercased()) }
            .filter { $0.deletingPathExtension().lastPathComponent.lowercased().contains(stem) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

private struct FFprobePayload: Decodable {
    let streams: [FFprobeStream]
    let format: FFprobeFormat?
}

private struct FFprobeStream: Decodable {
    let index: Int
    let codecName: String?
    let codecType: String?
    let channels: Int?
    let bitRate: String?
    let tags: FFprobeTags?
    let disposition: FFprobeDisposition?
}

private struct FFprobeTags: Decodable {
    let language: String?
    let title: String?
}

private struct FFprobeFormat: Decodable {
    let formatName: String?

    enum CodingKeys: String, CodingKey {
        case formatName = "format_name"
    }
}

private struct FFprobeDisposition: Decodable {
    let `default`: Int?
    let forced: Int?

    var description: String {
        let defaultBit = (`default` ?? 0) == 1 ? "default" : nil
        let forcedBit = (forced ?? 0) == 1 ? "forced" : nil
        return [defaultBit, forcedBit].compactMap { $0 }.joined(separator: ",")
    }
}

private extension FFprobeStream {
    enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case codecType = "codec_type"
        case channels
        case bitRate = "bit_rate"
        case tags
        case disposition
    }
}
