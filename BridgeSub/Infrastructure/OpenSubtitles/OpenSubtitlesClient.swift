import Foundation
import CryptoKit

final class OpenSubtitlesRESTClient: OpenSubtitlesServicing {
    private let session: URLSession
    private let credentialStore: any CredentialStore

    nonisolated(unsafe) private static var cachedToken: String?

    init(session: URLSession = .shared, credentialStore: any CredentialStore) {
        self.session = session
        self.credentialStore = credentialStore
    }

    #if DEBUG
    static func resetCachedTokenForTesting() {
        cachedToken = nil
    }
    #endif

    func validateConfiguration(username: String) throws {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowError.credentialsMissing("Enter an OpenSubtitles username before enabling downloads.")
        }

        let password = try credentialStore.load(account: "opensubtitles.password")
        guard let password, !password.isEmpty else {
            throw WorkflowError.credentialsMissing("OpenSubtitles password is missing from the keychain.")
        }

        let apiKey = try credentialStore.load(account: "opensubtitles.apiKey")
        guard let apiKey, !apiKey.isEmpty else {
            throw WorkflowError.credentialsMissing("OpenSubtitles API key is missing from the keychain.")
        }
    }

    func searchSubtitles(videoHash: String, languages: [String], videoURL: URL? = nil) async throws -> OpenSubtitleSearchResponse {
        let token = try await ensureToken()
        let currentApiKey = try credentialStore.load(account: "opensubtitles.apiKey") ?? ""
        let searchTarget = movieSearchTarget(from: videoURL)
        var filteredCount = 0

        let hashURL = subtitlesURL(queryItems: [
            URLQueryItem(name: "moviehash", value: videoHash),
            URLQueryItem(name: "languages", value: languages.joined(separator: ","))
        ])
        let hashResults = try await performSearch(url: hashURL, token: token, apiKey: currentApiKey)
        let rankedHashResults = filterAndRank(hashResults, target: searchTarget)
        filteredCount += rankedHashResults.filteredCount
        var results = rankedHashResults.results

        if results.isEmpty, let queryTitle = searchTarget.title, !queryTitle.isEmpty {
            var queryItems = [
                URLQueryItem(name: "query", value: queryTitle),
                URLQueryItem(name: "languages", value: languages.joined(separator: ",")),
                URLQueryItem(name: "type", value: "movie")
            ]
            if let year = searchTarget.year {
                queryItems.append(URLQueryItem(name: "year", value: String(year)))
            }

            let queryResults = try await performSearch(
                url: subtitlesURL(queryItems: queryItems),
                token: token,
                apiKey: currentApiKey
            )
            let rankedQueryResults = filterAndRank(queryResults, target: searchTarget)
            filteredCount += rankedQueryResults.filteredCount
            results = rankedQueryResults.results
        }

        return OpenSubtitleSearchResponse(
            results: results,
            filteredCount: filteredCount,
            queryTitle: searchTarget.title,
            queryYear: searchTarget.year
        )
    }

    private func performSearch(url: URL, token: String, apiKey: String) async throws -> [OpenSubtitleSearchResult] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("BridgeSub/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkflowError.networkError("Invalid response from OpenSubtitles")
        }

        if httpResponse.statusCode == 401 {
            Self.cachedToken = nil
            let newToken = try await ensureToken()
            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, _) = try await session.data(for: retryRequest)
            return try parseSearchResults(retryData)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkflowError.networkError("OpenSubtitles search failed: HTTP \(httpResponse.statusCode)")
        }

        return try parseSearchResults(data)
    }

    func downloadSubtitle(subtitleID: String) async throws -> URL {
        let token = try await ensureToken()
        let currentApiKey = try credentialStore.load(account: "opensubtitles.apiKey") ?? ""
        let url = URL(string: "https://api.opensubtitles.com/api/v1/download")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(currentApiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("BridgeSub/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["file_id": subtitleID, "sub_format": "srt"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WorkflowError.networkError("OpenSubtitles download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let link = json?["link"] as? String, let downloadURL = URL(string: link) else {
            throw WorkflowError.networkError("Invalid download URL from OpenSubtitles")
        }

        // Download the actual subtitle file
        let (fileData, _) = try await session.data(from: downloadURL)

        // Save to temp directory
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "\(subtitleID).srt"
        let fileURL = tempDir.appendingPathComponent(fileName)
        try fileData.write(to: fileURL)

        return fileURL
    }

    // MARK: - Private

    private struct MovieSearchTarget {
        let title: String?
        let year: Int?
        let tokens: Set<String>
        let releaseTokens: Set<String>
    }

    private func subtitlesURL(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.opensubtitles.com"
        components.path = "/api/v1/subtitles"
        components.queryItems = queryItems
        return components.url!
    }

    private func movieSearchTarget(from videoURL: URL?) -> MovieSearchTarget {
        guard let videoURL else {
            return MovieSearchTarget(title: nil, year: nil, tokens: [], releaseTokens: [])
        }

        let fileStem = videoURL.deletingPathExtension().lastPathComponent
        let parentName = videoURL.deletingLastPathComponent().lastPathComponent
        let parentYear = extractYear(from: parentName)
        let fileYear = extractYear(from: fileStem)
        let year = parentYear ?? fileYear

        let titleSource: String
        if parentYear != nil {
            titleSource = parentName
        } else if fileYear != nil {
            titleSource = fileStem
        } else {
            titleSource = parentName.isEmpty ? fileStem : parentName
        }

        let title = cleanMovieTitle(from: titleSource, year: year)
        let fallbackTitle = title.isEmpty ? cleanMovieTitle(from: fileStem, year: year) : title

        return MovieSearchTarget(
            title: fallbackTitle.isEmpty ? nil : fallbackTitle,
            year: year,
            tokens: meaningfulTokens(in: fallbackTitle),
            releaseTokens: meaningfulTokens(in: fileStem)
        )
    }

    private func cleanMovieTitle(from rawValue: String, year: Int?) -> String {
        var value = rawValue
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        if let year, let range = value.range(of: "\\(?\\b\(year)\\b\\)?", options: .regularExpression) {
            value = String(value[..<range.lowerBound])
        }

        value = value.replacingOccurrences(
            of: "\\b(2160p|1080p|720p|480p|uhd|hdr|hdr10|dv|dolby|vision|bluray|blu ray|brrip|webrip|web dl|dvdrip|remux|x264|x265|h264|h265|hevc|truehd|atmos|dts|aac|multi|proper|repack)\\b.*$",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        return value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractYear(from value: String) -> Int? {
        guard let range = value.range(of: "\\b(19|20)\\d{2}\\b", options: .regularExpression) else {
            return nil
        }
        return Int(value[range])
    }

    private func filterAndRank(
        _ results: [OpenSubtitleSearchResult],
        target: MovieSearchTarget
    ) -> (results: [OpenSubtitleSearchResult], filteredCount: Int) {
        var filteredCount = 0
        var accepted: [(OpenSubtitleSearchResult, Double)] = []

        for result in results {
            guard isAcceptable(result, target: target) else {
                filteredCount += 1
                continue
            }
            accepted.append((result, score(result, target: target)))
        }

        return (
            accepted
                .sorted { lhs, rhs in
                    if lhs.1 == rhs.1 {
                        return lhs.0.downloads > rhs.0.downloads
                    }
                    return lhs.1 > rhs.1
                }
                .map(\.0),
            filteredCount
        )
    }

    private func isAcceptable(_ result: OpenSubtitleSearchResult, target: MovieSearchTarget) -> Bool {
        if result.movieHashMatch {
            return true
        }

        if let featureType = result.featureType,
           !featureType.localizedCaseInsensitiveContains("movie") {
            return false
        }

        if let targetYear = target.year,
           let featureYear = result.featureYear,
           featureYear != targetYear {
            return false
        }

        guard let targetTitle = target.title, !targetTitle.isEmpty else {
            return true
        }

        let candidateText = [
            result.featureTitle,
            result.release,
            result.fileName
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        let titleScore = similarity(between: targetTitle, and: result.featureTitle ?? candidateText)
        let releaseOverlap = tokenOverlap(target.tokens, meaningfulTokens(in: candidateText))
        if target.year == nil {
            return max(titleScore, releaseOverlap) >= 0.45
        }
        return max(titleScore, releaseOverlap) >= 0.35 || result.featureYear == target.year
    }

    private func score(_ result: OpenSubtitleSearchResult, target: MovieSearchTarget) -> Double {
        let candidateText = [result.featureTitle, result.release, result.fileName].compactMap { $0 }.joined(separator: " ")
        var value = 0.0

        if result.movieHashMatch { value += 100 }
        if let targetYear = target.year, result.featureYear == targetYear { value += 25 }
        if let title = target.title {
            value += similarity(between: title, and: result.featureTitle ?? candidateText) * 25
        }
        value += tokenOverlap(target.releaseTokens, meaningfulTokens(in: candidateText)) * 15
        if result.fromTrusted { value += 8 }
        if !result.hearingImpaired { value += 2 }
        if !result.foreignPartsOnly { value += 4 }
        if !result.aiTranslated && !result.machineTranslated { value += 2 }
        if result.reviewSuggested { value -= 8 }
        value += min(Double(result.votes ?? 0), 20) * 0.3
        value += min(result.rating ?? 0, 10) * 0.5
        value += min(log10(Double(max(result.downloads, 1))), 5)

        if candidateText.localizedCaseInsensitiveContains("forced") || result.foreignPartsOnly {
            value -= 20
        }

        return value
    }

    private func similarity(between lhs: String, and rhs: String) -> Double {
        tokenOverlap(meaningfulTokens(in: lhs), meaningfulTokens(in: rhs))
    }

    private func tokenOverlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.count)
    }

    private func meaningfulTokens(in value: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "a", "an", "of", "and", "or", "de", "le", "la", "les", "du", "part",
            "uhd", "hdr", "remux", "bluray", "blu", "ray", "web", "dl", "rip", "x264",
            "x265", "h264", "h265", "hevc", "truehd", "atmos", "aac", "dts", "multi",
            "forced", "eng", "english", "srt", "ass", "vtt"
        ]
        return Set(value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                token.count > 1 && !stopWords.contains(token) && Int(token) == nil
            })
    }

    private func ensureToken() async throws -> String {
        if let cached = Self.cachedToken { return cached }

        // Reload API key from keychain each time (not just at init) to pick up changes
        let currentApiKey = try credentialStore.load(account: "opensubtitles.apiKey") ?? ""

        let loginURL = URL(string: "https://api.opensubtitles.com/api/v1/login")!
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(currentApiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("BridgeSub/1.0", forHTTPHeaderField: "User-Agent")

        let username = try credentialStore.load(account: "opensubtitles.username") ?? ""
        let password = try credentialStore.load(account: "opensubtitles.password") ?? ""
        let body: [String: String] = ["username": username, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WorkflowError.credentialsMissing("OpenSubtitles login failed")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["token"] as? String else {
            throw WorkflowError.credentialsMissing("No token received from OpenSubtitles")
        }

        Self.cachedToken = token
        return token
    }

    private func parseSearchResults(_ data: Data) throws -> [OpenSubtitleSearchResult] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any],
              let dataArray = root["data"] as? [[String: Any]]
        else {
            return []
        }

        return dataArray.compactMap { item -> OpenSubtitleSearchResult? in
            guard let id = item["id"] as? String,
                  let attrs = item["attributes"] as? [String: Any],
                  let files = attrs["files"] as? [[String: Any]],
                  let file = files.first,
                  let fileID = file["file_id"] as? Int,
                  let fileName = file["file_name"] as? String
            else { return nil }

            let languageCode = (attrs["language"] as? String ?? "unknown").lowercased()
            let langName = languageCode == "ze" ? "Chinese bilingual" : languageCode
            let downloads = attrs["download_count"] as? Int ?? 0
            let hd = (attrs["hd"] as? Bool) ?? false
            let hearingImpaired = attrs["hearing_impaired"] as? Bool ?? false
            let label = hearingImpaired ? "\(langName) (HI)" : langName

            // Extract format from file extension
            let parsedFormat = (fileName as NSString).pathExtension.uppercased()
            let format = parsedFormat.isEmpty ? (attrs["format"] as? String ?? "SRT").uppercased() : parsedFormat

            // Additional quality info from API
            let fileSize = int64Value(attrs["file_size"])
            let fps = doubleValue(attrs["fps"])
            let votes = intValue(attrs["votes"])
            let rating = doubleValue(attrs["rating"])
            let uploadDate = attrs["upload_date"] as? String
            let featureDetails = attrs["feature_details"] as? [String: Any]
            let featureTitle = featureTitle(from: featureDetails)
            let featureYear = intValue(featureDetails?["year"])
            let featureType = featureDetails?["feature_type"] as? String
            let movieHashMatch = (attrs["moviehash_match"] as? Bool) ?? false
            let release = attrs["release"] as? String
            let fromTrusted = (attrs["from_trusted"] as? Bool) ?? false
            let foreignPartsOnly = (attrs["foreign_parts_only"] as? Bool) ?? false
            let aiTranslated = (attrs["ai_translated"] as? Bool) ?? false
            let machineTranslated = (attrs["machine_translated"] as? Bool) ?? false
            let comments = stringValue(attrs["comments"])
                ?? stringValue(attrs["subtitle_comments"])
                ?? stringValue(attrs["description"])

            return OpenSubtitleSearchResult(
                id: id,
                languageCode: languageCode,
                languageName: label,
                fileFormat: format,
                downloads: downloads,
                hd: hd,
                subtitleID: String(fileID),
                fileSize: fileSize,
                fps: fps,
                votes: votes,
                rating: rating,
                hearingImpaired: hearingImpaired,
                uploadDate: uploadDate,
                featureTitle: featureTitle,
                featureYear: featureYear,
                featureType: featureType,
                movieHashMatch: movieHashMatch,
                release: release,
                fileName: fileName,
                fromTrusted: fromTrusted,
                foreignPartsOnly: foreignPartsOnly,
                aiTranslated: aiTranslated,
                machineTranslated: machineTranslated,
                comments: comments
            )
        }
    }

    private func featureTitle(from details: [String: Any]?) -> String? {
        let rawTitle = stringValue(details?["title"]) ?? stringValue(details?["movie_name"])
        guard let rawTitle else { return nil }
        let cleaned = rawTitle
            .replacingOccurrences(
                of: #"^\s*(19|20)\d{2}\s*[-:]\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int64:
            return value
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value)
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    // MARK: - MovieHash (OpenSubtitles standard)

    static func computeMovieHash(fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        let fileSize = try fileHandle.seekToEnd()
        try fileHandle.seek(toOffset: 0)

        let chunkSize = 64 * 1024
        var hashData = Data()

        // First 64KB
        if let firstChunk = try fileHandle.read(upToCount: chunkSize) {
            hashData.append(firstChunk)
        }

        // Last 64KB
        if fileSize > UInt64(chunkSize) {
            try fileHandle.seek(toOffset: fileSize - UInt64(chunkSize))
            if let lastChunk = try fileHandle.read(upToCount: chunkSize) {
                hashData.append(lastChunk)
            }
        }

        // File size (8 bytes, little endian) - using UInt64 directly
        var sizeLE = fileSize.littleEndian
        withUnsafeBytes(of: &sizeLE) { bytes in
            hashData.append(contentsOf: bytes)
        }

        let digest = Insecure.MD5.hash(data: hashData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
