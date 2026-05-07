import Foundation

struct MediaToolRegistry: Sendable {
    private let bundleToolsURL: URL?
    private let systemExecutableCandidates: [MediaTool: [String]]

    init(
        bundleToolsURL: URL? = Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true),
        systemExecutableCandidates: [MediaTool: [String]] = MediaToolRegistry.defaultSystemExecutableCandidates
    ) {
        self.bundleToolsURL = bundleToolsURL
        self.systemExecutableCandidates = systemExecutableCandidates
    }

    func executablePath(for tool: MediaTool) -> String? {
        status(for: tool).resolvedPath
    }

    func status(for tool: MediaTool) -> MediaToolStatus {
        if let bundledPath = bundledExecutablePath(for: tool) {
            return MediaToolStatus(
                tool: tool,
                origin: .bundled,
                resolvedPath: bundledPath,
                version: nil
            )
        }

        if let systemPath = systemExecutablePath(for: tool) {
            return MediaToolStatus(
                tool: tool,
                origin: .system,
                resolvedPath: systemPath,
                version: nil
            )
        }

        return MediaToolStatus(
            tool: tool,
            origin: .missing,
            resolvedPath: nil,
            version: nil
        )
    }

    func allStatuses() -> [MediaToolStatus] {
        MediaTool.allCases.map(status(for:))
    }

    private func bundledExecutablePath(for tool: MediaTool) -> String? {
        guard let bundleToolsURL else { return nil }
        let candidatePath = bundleToolsURL.appendingPathComponent(tool.rawValue).path
        guard FileManager.default.isExecutableFile(atPath: candidatePath) else { return nil }
        return candidatePath
    }

    private func systemExecutablePath(for tool: MediaTool) -> String? {
        let candidates = systemExecutableCandidates[tool] ?? []
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static let defaultSystemExecutableCandidates: [MediaTool: [String]] = [
        .ffprobe: [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ],
        .ffmpeg: [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ],
        .mkvextract: [
            "/opt/homebrew/bin/mkvextract",
            "/usr/local/bin/mkvextract",
            "/usr/bin/mkvextract"
        ],
        .mkvmerge: [
            "/opt/homebrew/bin/mkvmerge",
            "/usr/local/bin/mkvmerge",
            "/usr/bin/mkvmerge"
        ]
    ]
}
