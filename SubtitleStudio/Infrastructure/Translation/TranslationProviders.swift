import Foundation

struct OllamaTranslationService: TranslationServicing {
    let kind: TranslationProviderKind = .ollama
    let capabilities = TranslationProviderCapabilities()

    private let session: URLSession
    private let credentialStore: any CredentialStore

    init(session: URLSession? = nil, credentialStore: any CredentialStore) {
        self.credentialStore = credentialStore
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    func validateConfiguration(settings: ProviderSettings) throws {
        guard URL(string: settings.ollamaBaseURL) != nil else {
            throw WorkflowError.credentialsMissing("Ollama base URL is invalid.")
        }
        guard !settings.ollamaModel.isEmpty else {
            throw WorkflowError.credentialsMissing("Choose a local model for Ollama.")
        }
    }

    func translate(_ request: TranslationRequest, settings: ProviderSettings) async throws -> TranslationResponse {
        if settings.useOpenAICompatibleEndpoint {
            return try await translateWithOpenAICompatibleEndpoint(
                request: request,
                baseURL: settings.ollamaBaseURL,
                model: settings.ollamaModel
            )
        }
        return try await translateWithOllamaEndpoint(
            translationRequest: request,
            baseURL: settings.ollamaBaseURL,
            model: settings.ollamaModel
        )
    }

    private func translateWithOllamaEndpoint(translationRequest: TranslationRequest, baseURL: String, model: String) async throws -> TranslationResponse {
        let url = try endpointURL(baseURL: baseURL, path: "/api/chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": serializeMessages(translationRequest.messages),
            "stream": false
        ])

        let data = try await send(urlRequest, errorPrefix: "Ollama translation failed")
        let json = try decodeJSONObject(from: data, errorPrefix: "Invalid Ollama response")
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            throw WorkflowError.networkError("Invalid Ollama response: missing message content.")
        }
        return TranslationResponse(content: content, usedStructuredOutput: false)
    }

    private func translateWithOpenAICompatibleEndpoint(
        request translationRequest: TranslationRequest,
        baseURL: String,
        model: String
    ) async throws -> TranslationResponse {
        let url = try endpointURL(baseURL: baseURL, path: "/v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "messages": serializeMessages(translationRequest.messages),
            "stream": false
        ]
        if case .jsonObject(let schemaName) = translationRequest.responseFormat {
            body["response_format"] = jsonSchemaResponseFormat(schemaName: schemaName)
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(urlRequest, errorPrefix: "Ollama OpenAI-compatible translation failed")
        return try parseOpenAICompatibleContent(
            from: data,
            errorPrefix: "Invalid Ollama OpenAI-compatible response",
            usedStructuredOutput: translationRequest.responseFormat != .plainText
        )
    }

    private func endpointURL(baseURL: String, path: String) throws -> URL {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: trimmedBaseURL + normalizedPath) else {
            throw WorkflowError.networkError("Invalid translation endpoint URL.")
        }
        return url
    }

    private func send(_ request: URLRequest, errorPrefix: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw WorkflowError.networkError("\(errorPrefix): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1), body: \(body.prefix(240))")
        }
        return data
    }

    private func decodeJSONObject(from data: Data, errorPrefix: String) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw WorkflowError.networkError("\(errorPrefix): \(body.prefix(240))")
        }
        return json
    }

    private func parseOpenAICompatibleContent(
        from data: Data,
        errorPrefix: String,
        usedStructuredOutput: Bool
    ) throws -> TranslationResponse {
        let json = try decodeJSONObject(from: data, errorPrefix: errorPrefix)
        guard let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            throw WorkflowError.networkError("\(errorPrefix): missing choices[0].message.content.")
        }
        return TranslationResponse(content: content, usedStructuredOutput: usedStructuredOutput)
    }

    private func serializeMessages(_ messages: [TranslationMessage]) -> [[String: String]] {
        messages.map { message in
            [
                "role": message.role.rawValue,
                "content": message.content
            ]
        }
    }

    private func jsonSchemaResponseFormat(schemaName: String) -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": schemaName,
                "strict": true,
                "schema": [
                    "type": "object",
                    "additionalProperties": [
                        "type": "string"
                    ]
                ]
            ]
        ]
    }
}

struct OpenAICompatibleTranslationService: TranslationServicing {
    let kind: TranslationProviderKind = .openAICompatible
    let capabilities = TranslationProviderCapabilities(
        supportsStructuredOutput: true,
        supportsStreamingProgress: false,
        supportsImmediateCancellation: false,
        supportsPromptCacheHints: true
    )

    private let session: URLSession
    private let credentialStore: any CredentialStore

    init(session: URLSession? = nil, credentialStore: any CredentialStore) {
        self.session = session ?? .shared
        self.credentialStore = credentialStore
    }

    func validateConfiguration(settings: ProviderSettings) throws {
        guard URL(string: settings.openAIBaseURL) != nil else {
            throw WorkflowError.credentialsMissing("OpenAI-compatible base URL is invalid.")
        }
        guard !settings.openAIModel.isEmpty else {
            throw WorkflowError.credentialsMissing("Choose a cloud model.")
        }
        let apiKey = try loadAPIKey(settings: settings)
        guard let apiKey, !apiKey.isEmpty else {
            throw WorkflowError.credentialsMissing("Cloud API key is missing from the keychain.")
        }
    }

    func translate(_ translationRequest: TranslationRequest, settings: ProviderSettings) async throws -> TranslationResponse {
        guard let url = URL(string: settings.openAIBaseURL + "/chat/completions") else {
            throw WorkflowError.networkError("Invalid OpenAI-compatible endpoint URL.")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(try loadAPIKey(settings: settings) ?? "")", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": settings.openAIModel,
            "messages": serializeMessages(translationRequest.messages),
            "stream": false
        ]
        if case .jsonObject(let schemaName) = translationRequest.responseFormat {
            body["response_format"] = jsonSchemaResponseFormat(schemaName: schemaName)
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw WorkflowError.networkError("OpenAI-compatible translation failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1), body: \(body.prefix(240))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw WorkflowError.networkError("Invalid OpenAI-compatible response: \(body.prefix(240))")
        }

        return TranslationResponse(
            content: content,
            usedStructuredOutput: translationRequest.responseFormat != .plainText
        )
    }

    private func serializeMessages(_ messages: [TranslationMessage]) -> [[String: String]] {
        messages.map { message in
            [
                "role": message.role.rawValue,
                "content": message.content
            ]
        }
    }

    private func jsonSchemaResponseFormat(schemaName: String) -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": schemaName,
                "strict": true,
                "schema": [
                    "type": "object",
                    "additionalProperties": [
                        "type": "string"
                    ]
                ]
            ]
        ]
    }

    private func loadAPIKey(settings: ProviderSettings) throws -> String? {
        if let scopedAPIKey = try credentialStore.load(account: settings.cloudAPIKeyAccount), !scopedAPIKey.isEmpty {
            return scopedAPIKey
        }
        if settings.cloudAPIKeyAccount != "openai.apiKey" {
            return try credentialStore.load(account: "openai.apiKey")
        }
        return nil
    }
}
