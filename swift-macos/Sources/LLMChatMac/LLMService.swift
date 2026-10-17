import Foundation

final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let redirected = request.url,
              Self.sameOrigin(original, redirected)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
            lhs.host?.lowercased() == rhs.host?.lowercased() &&
            effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

@MainActor
final class LLMService {
    private let store: ConversationStore
    private let redirectDelegate: SameOriginRedirectDelegate
    private let session: URLSession
    private let router = ModelRouter()
    var onDebugEvent: ((String) -> Void)?

    init(store: ConversationStore) {
        self.store = store
        let redirectDelegate = SameOriginRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
    }

    func probe(settings: AppSettings) async throws -> LLMStatus {
        let url = try modelsURL(baseURL: settings.baseURL, interfaceType: settings.interfaceType)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = AppDefaults.requestTimeout
        applyHeaders(to: &request, settings: settings, includeContentType: false)
        logRequest(label: "probe", url: url, headers: request.allHTTPHeaderFields ?? [:], body: nil)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMServiceError.request(L10n.choose("Neplatná odpověď z \(url.absoluteString)", "Invalid response from \(url.absoluteString)"))
            }
            logResponse(label: "probe", url: url, status: http.statusCode, data: data, apiKey: settings.apiKey)
            guard (200 ..< 300).contains(http.statusCode) else {
                let body = redactedText(String(data: data, encoding: .utf8) ?? "", apiKey: settings.apiKey)
                throw LLMServiceError.http(status: http.statusCode, body: body, url: url.absoluteString)
            }
            return try parseProbeResponse(data: data, settings: settings, url: url)
        } catch let error as LLMServiceError {
            logError(label: "probe", url: url, error: error.localizedDescription)
            throw error
        } catch {
            let description = requestErrorDescription(error, url: url.absoluteString)
            logError(label: "probe", url: url, error: description)
            throw LLMServiceError.request(description)
        }
    }

    func send(
        conversation: Conversation,
        userContent: String,
        currentAttachments: [AttachmentMetadata],
        settings: AppSettings,
        fallbackSettings: [AppSettings] = []
    ) async throws -> LLMChatResult {
        let attachmentBlock = try attachmentsAsPromptBlock(currentAttachments)
        let ballast = simulationBallastText(
            enabled: settings.simulateContextFill,
            maxTokens: settings.maxTokens
        )
        let promptMessages = buildPrompt(
            conversation: conversation,
            userContent: userContent,
            attachmentBlock: attachmentBlock,
            includeLatestMessages: false,
            simulationBallast: ballast
        )
        router.update(policy: settings.routePolicy)
        let estimatedInputTokens = estimateInputTokens(promptMessages)
        let candidates = try router.orderedCandidates(
            primary: settings,
            fallbacks: fallbackSettings,
            estimatedInputTokens: estimatedInputTokens,
            requestedOutputTokens: max(1, settings.maxTokens)
        )

        for (index, candidate) in candidates.enumerated() {
            if index > 0 {
                log("### \(timestamp()) ROUTER\n\(L10n.choose("Přepínám na záložní endpoint", "Switching to fallback endpoint")): \(candidate.settings.baseURL) / \(candidate.settings.model)\n")
            }
            do {
                let result = try await sendChat(
                    promptMessages: promptMessages,
                    currentAttachments: currentAttachments,
                    settings: candidate.settings,
                    maxTokens: max(1, candidate.settings.maxTokens),
                    enableThinking: candidate.settings.enableThinking,
                    requestLabel: index == 0 ? "chat" : "chat-fallback"
                )
                router.recordSuccess(candidateID: candidate.id)
                return result
            } catch {
                let retryable = router.isRetryable(error)
                if retryable {
                    router.recordFailure(candidateID: candidate.id)
                }
                if !retryable || index == candidates.count - 1 {
                    throw error
                }
                log("### \(timestamp()) ROUTER\n\(L10n.choose("Endpoint selhal, zkouším další", "Endpoint failed, trying the next one")): \(candidate.settings.baseURL)\n")
            }
        }
        throw LLMServiceError.request(L10n.choose("Není dostupný žádný LLM endpoint.", "No LLM endpoint is available."))
    }

    func sendStreaming(
        conversation: Conversation,
        userContent: String,
        currentAttachments: [AttachmentMetadata],
        settings: AppSettings,
        fallbackSettings: [AppSettings] = [],
        onEvent: (LLMEvent) -> Void
    ) async throws -> LLMChatResult {
        let attachmentBlock = try attachmentsAsPromptBlock(currentAttachments)
        let promptMessages = buildPrompt(
            conversation: conversation,
            userContent: userContent,
            attachmentBlock: attachmentBlock,
            includeLatestMessages: false,
            simulationBallast: simulationBallastText(enabled: settings.simulateContextFill, maxTokens: settings.maxTokens)
        )
        let normalizedRequest = LLMRequest(
            id: UUID().uuidString,
            messages: promptMessages,
            attachments: currentAttachments,
            maxTokens: max(1, settings.maxTokens),
            reasoningMode: settings.reasoningMode,
            structuredOutput: nil
        )

        router.update(policy: settings.routePolicy)
        let candidates = try router.orderedCandidates(
            primary: settings,
            fallbacks: fallbackSettings,
            estimatedInputTokens: estimateInputTokens(promptMessages),
            requestedOutputTokens: normalizedRequest.maxTokens
        )

        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            let endpoint = endpointDescriptor(for: candidate.settings, candidateID: candidate.id)
            onEvent(.started(requestId: normalizedRequest.id, endpoint: endpoint))
            if index > 0 {
                log("### \(timestamp()) ROUTER\n\(L10n.choose("Přepínám na záložní endpoint", "Switching to fallback endpoint")): \(candidate.settings.baseURL) / \(candidate.settings.model)\n")
            }
            do {
                var result = try await streamCandidate(
                    request: normalizedRequest,
                    settings: candidate.settings,
                    requestLabel: index == 0 ? "chat-stream" : "chat-stream-fallback",
                    onEvent: onEvent
                )
                result.endpoint = endpoint
                result.requestId = normalizedRequest.id
                router.recordSuccess(candidateID: candidate.id)
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let retryable = router.isRetryable(error)
                if retryable {
                    router.recordFailure(candidateID: candidate.id)
                }
                if !retryable || index == candidates.count - 1 {
                    throw error
                }
                log("### \(timestamp()) ROUTER\n\(L10n.choose("Stream selhal, zkouším další endpoint", "Stream failed, trying the next endpoint")): \(candidate.settings.baseURL)\n")
            }
        }
        throw LLMServiceError.request(L10n.choose("Není dostupný žádný LLM endpoint.", "No LLM endpoint is available."))
    }

    func generateConversationTitle(conversation: Conversation, settings: AppSettings) async throws -> ConversationTitle {
        let transcript = conversation.messages.prefix(4).map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
        let schema = StructuredOutputSchema(
            name: "conversation_title",
            description: "A short title for the conversation",
            schema: [
                "type": "object",
                "properties": ["title": ["type": "string"]],
                "required": ["title"],
                "additionalProperties": false,
            ]
        )
        let messages = [
            PromptMessage(role: .system, content: "Return a concise conversation title with at most 8 words."),
            PromptMessage(role: .user, content: transcript),
        ]
        let result = try await sendStructured(messages: messages, schema: schema, settings: settings, maxTokens: 96)
        return try decodeStructured(ConversationTitle.self, from: result.text, jobName: schema.name)
    }

    func compressConversation(conversation: inout Conversation, settings: AppSettings) async {
        do {
            let summaryPrompt = buildSummaryPrompt(conversation: conversation)
            let schema = StructuredOutputSchema(
                name: "summary_v2",
                description: "A compact conversation summary",
                schema: [
                    "type": "object",
                    "properties": ["summary": ["type": "string"]],
                    "required": ["summary"],
                    "additionalProperties": false,
                ]
            )
            let result = try await sendStructured(
                messages: summaryPrompt,
                schema: schema,
                settings: settings,
                maxTokens: min(512, max(128, settings.maxTokens))
            )
            let summary = try decodeStructured(SummaryV2.self, from: result.text, jobName: schema.name)
            conversation.summary = summary.summary
            conversation.messages = recentMessages(conversation.messages)
            log("### \(timestamp()) COMPRESSION\n\(L10n.choose("Konverzace byla komprimována do shrnutí.", "Conversation was compressed into a summary."))\n")
        } catch {
            logError(
                label: "summary",
                url: try? chatURL(baseURL: settings.baseURL, interfaceType: settings.interfaceType, model: settings.model),
                error: error.localizedDescription
            )
        }
    }

    private func streamCandidate(
        request normalizedRequest: LLMRequest,
        settings: AppSettings,
        requestLabel: String,
        onEvent: (LLMEvent) -> Void
    ) async throws -> LLMChatResult {
        let url = try streamingChatURL(
            baseURL: settings.baseURL,
            interfaceType: settings.interfaceType,
            model: settings.model
        )
        let body = try buildBody(
            promptMessages: normalizedRequest.messages,
            currentAttachments: normalizedRequest.attachments,
            settings: settings,
            maxTokens: normalizedRequest.maxTokens,
            enableThinking: normalizedRequest.reasoningMode != .off,
            stream: true,
            structuredOutput: normalizedRequest.structuredOutput
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppDefaults.requestTimeout
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyHeaders(to: &request, settings: settings, includeContentType: true)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        logRequest(label: requestLabel, url: url, headers: request.allHTTPHeaderFields ?? [:], body: body)

        let startedAt = Date()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMServiceError.request(L10n.choose("Neplatná odpověď z \(url.absoluteString)", "Invalid response from \(url.absoluteString)"))
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                    if errorData.count >= 16_384 { break }
                }
                let message = redactedText(String(data: errorData, encoding: .utf8) ?? "", apiKey: settings.apiKey)
                throw LLMServiceError.http(status: http.statusCode, body: message, url: url.absoluteString)
            }

            var textValue = ""
            var reasoningValue = ""
            var usage = LLMUsageMetrics(promptTokens: nil, completionTokens: nil, totalTokens: nil)
            var finishReason: String?
            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                let events = try decodeStreamLine(rawLine, interfaceType: settings.interfaceType)
                for event in events {
                    switch event {
                    case let .textDelta(delta):
                        textValue += delta
                    case let .reasoningDelta(delta):
                        reasoningValue += delta
                    case let .usage(metrics):
                        usage = merging(usage, with: metrics)
                    case let .completed(reason):
                        finishReason = reason ?? finishReason
                    case .started:
                        break
                    }
                    onEvent(event)
                }
            }
            guard !textValue.isEmpty || !reasoningValue.isEmpty else {
                throw LLMServiceError.invalidResponse
            }
            if textValue.isEmpty {
                textValue = L10n.choose(
                    "Model vrátil pouze uvažování a nedokončil finální odpověď.",
                    "The model returned reasoning only and did not complete a final answer."
                )
            }
            let latency = Int(Date().timeIntervalSince(startedAt) * 1_000)
            onEvent(.completed(finishReason: finishReason))
            log("<<< \(timestamp()) STREAM [\(requestLabel.uppercased())]\nURL: \(url.absoluteString)\nStatus: \(http.statusCode)\nLatency: \(latency) ms\n")
            return LLMChatResult(
                text: textValue,
                reasoning: reasoningValue,
                usage: usage,
                latencyMs: latency,
                finishReason: finishReason
            )
        } catch is CancellationError {
            log("### \(timestamp()) CANCEL [\(requestLabel.uppercased())]\n\(L10n.choose("Generování bylo zastaveno uživatelem.", "Generation was stopped by the user."))\n")
            throw CancellationError()
        } catch let error as LLMServiceError {
            logError(label: requestLabel, url: url, error: error.localizedDescription)
            throw error
        } catch {
            let nsError = error as NSError
            if Task.isCancelled || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                throw CancellationError()
            }
            let description = requestErrorDescription(error, url: url.absoluteString)
            logError(label: requestLabel, url: url, error: description)
            throw LLMServiceError.request(description)
        }
    }

    private func sendStructured(
        messages: [PromptMessage],
        schema: StructuredOutputSchema,
        settings: AppSettings,
        maxTokens: Int
    ) async throws -> LLMChatResult {
        var jobSettings = settings
        jobSettings.reasoningMode = .off
        return try await sendChat(
            promptMessages: messages,
            currentAttachments: [],
            settings: jobSettings,
            maxTokens: maxTokens,
            enableThinking: false,
            requestLabel: "structured-\(schema.name)",
            structuredOutput: schema
        )
    }

    private func decodeStructured<T: Decodable>(_ type: T.Type, from text: String, jobName: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            candidate = String(trimmed[start ... end])
        } else {
            throw LLMServiceError.structuredOutput(job: jobName, detail: L10n.choose("Odpověď neobsahuje JSON objekt.", "The response does not contain a JSON object."))
        }
        do {
            return try JSONDecoder().decode(type, from: Data(candidate.utf8))
        } catch {
            throw LLMServiceError.structuredOutput(job: jobName, detail: error.localizedDescription)
        }
    }

    private func endpointDescriptor(for settings: AppSettings, candidateID: String) -> LLMEndpointDescriptor {
        LLMEndpointDescriptor(
            id: candidateID,
            displayName: settings.activeProfile?.title ?? settings.model,
            baseURL: settings.baseURL,
            model: settings.model,
            interfaceType: settings.interfaceType
        )
    }

    private func sendChat(
        promptMessages: [PromptMessage],
        currentAttachments: [AttachmentMetadata],
        settings: AppSettings,
        maxTokens: Int,
        enableThinking: Bool,
        requestLabel: String,
        structuredOutput: StructuredOutputSchema? = nil
    ) async throws -> LLMChatResult {
        let url = try chatURL(baseURL: settings.baseURL, interfaceType: settings.interfaceType, model: settings.model)
        let body = try buildBody(
            promptMessages: promptMessages,
            currentAttachments: currentAttachments,
            settings: settings,
            maxTokens: maxTokens,
            enableThinking: enableThinking,
            structuredOutput: structuredOutput
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppDefaults.requestTimeout
        applyHeaders(to: &request, settings: settings, includeContentType: true)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        logRequest(label: requestLabel, url: url, headers: request.allHTTPHeaderFields ?? [:], body: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMServiceError.request(L10n.choose("Neplatná odpověď z \(url.absoluteString)", "Invalid response from \(url.absoluteString)"))
            }
            logResponse(label: requestLabel, url: url, status: http.statusCode, data: data, apiKey: settings.apiKey)
            guard (200 ..< 300).contains(http.statusCode) else {
                let body = redactedText(String(data: data, encoding: .utf8) ?? "", apiKey: settings.apiKey)
                throw LLMServiceError.http(status: http.statusCode, body: body, url: url.absoluteString)
            }
            return try extractContent(from: data, interfaceType: settings.interfaceType, maxTokens: maxTokens, enableThinking: enableThinking)
        } catch let error as LLMServiceError {
            logError(label: requestLabel, url: url, error: error.localizedDescription)
            throw error
        } catch {
            let description = requestErrorDescription(error, url: url.absoluteString)
            logError(label: requestLabel, url: url, error: description)
            throw LLMServiceError.request(description)
        }
    }

    private func buildBody(
        promptMessages: [PromptMessage],
        currentAttachments: [AttachmentMetadata],
        settings: AppSettings,
        maxTokens: Int,
        enableThinking: Bool,
        stream: Bool = false,
        structuredOutput: StructuredOutputSchema? = nil
    ) throws -> [String: Any] {
        switch settings.interfaceType {
        case .openAICompatible:
            var body: [String: Any] = [
                "model": settings.model,
                "messages": try prepareOpenAIMessages(promptMessages, attachments: currentAttachments),
                "max_tokens": maxTokens,
                "stream": stream,
                "chat_template_kwargs": [
                    "enable_thinking": enableThinking,
                ],
            ]
            if stream {
                body["stream_options"] = ["include_usage": true]
            }
            if settings.reasoningMode != .off {
                body["reasoning_effort"] = settings.reasoningMode.rawValue
            }
            if let structuredOutput {
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": [
                        "name": structuredOutput.name,
                        "description": structuredOutput.description,
                        "strict": true,
                        "schema": structuredOutput.schema,
                    ],
                ]
            }
            return body
        case .ollama:
            var body: [String: Any] = [
                "model": settings.model,
                "messages": try prepareOllamaMessages(promptMessages, attachments: currentAttachments),
                "stream": stream,
                "think": enableThinking,
                "options": [
                    "num_predict": maxTokens,
                ],
            ]
            if let structuredOutput {
                body["format"] = structuredOutput.schema
            }
            return body
        case .anthropic:
            var body = try buildAnthropicBody(
                promptMessages: promptMessages,
                attachments: currentAttachments,
                model: settings.model,
                maxTokens: maxTokens,
                enableThinking: enableThinking
            )
            if enableThinking {
                body["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": settings.reasoningMode == .low ? 1_024 : max(1_024, min(maxTokens, 4_096)),
                ]
            }
            body["stream"] = stream
            if let structuredOutput {
                body["system"] = ((body["system"] as? String).map { $0 + "\n\n" } ?? "")
                    + "Return only valid JSON matching this schema: \(prettyJSONObject(structuredOutput.schema))"
            }
            return body
        case .gemini:
            var body = try buildGeminiBody(
                promptMessages: promptMessages,
                attachments: currentAttachments,
                maxTokens: maxTokens,
                reasoningMode: settings.reasoningMode,
                model: settings.model
            )
            if let structuredOutput {
                var generation = (body["generationConfig"] as? [String: Any]) ?? [:]
                generation["responseMimeType"] = "application/json"
                generation["responseJsonSchema"] = structuredOutput.schema
                body["generationConfig"] = generation
            }
            return body
        }
    }

    private func prepareOpenAIMessages(_ promptMessages: [PromptMessage], attachments: [AttachmentMetadata]) throws -> [[String: Any]] {
        var prepared: [[String: Any]] = promptMessages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let mediaAttachments = attachments.filter { isImageMime($0.mimeType) || isVideoMime($0.mimeType) }
        guard !mediaAttachments.isEmpty, var last = prepared.last else {
            return prepared
        }
        guard (last["role"] as? String) == MessageRole.user.rawValue else {
            return prepared
        }

        var contentParts: [[String: Any]] = []
        if let text = last["content"] as? String, !text.isEmpty {
            contentParts.append(["type": "text", "text": text])
        }

        for attachment in mediaAttachments {
            let data = try store.loadAttachmentData(attachment)
            let encoded = data.base64EncodedString()
            let dataURL = "data:\(attachment.mimeType);base64,\(encoded)"
            if isImageMime(attachment.mimeType) {
                contentParts.append([
                    "type": "image_url",
                    "image_url": ["url": dataURL],
                ])
            } else if isVideoMime(attachment.mimeType) {
                contentParts.append([
                    "type": "video_url",
                    "video_url": ["url": dataURL],
                ])
            }
        }

        last["content"] = contentParts
        prepared[prepared.count - 1] = last
        return prepared
    }

    private func prepareOllamaMessages(_ promptMessages: [PromptMessage], attachments: [AttachmentMetadata]) throws -> [[String: Any]] {
        var prepared: [[String: Any]] = promptMessages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let imageAttachments = attachments.filter { isImageMime($0.mimeType) }
        guard !imageAttachments.isEmpty, var last = prepared.last else {
            return prepared
        }
        guard (last["role"] as? String) == MessageRole.user.rawValue else {
            return prepared
        }
        last["images"] = try imageAttachments.map { attachment in
            try store.loadAttachmentData(attachment).base64EncodedString()
        }
        prepared[prepared.count - 1] = last
        return prepared
    }

    private func buildAnthropicBody(
        promptMessages: [PromptMessage],
        attachments: [AttachmentMetadata],
        model: String,
        maxTokens: Int,
        enableThinking: Bool
    ) throws -> [String: Any] {
        let systemMessages = promptMessages.filter { $0.role == .system }.map(\.content).filter { !$0.isEmpty }
        let nonSystemMessages = promptMessages.filter { $0.role != .system }

        var messages: [[String: Any]] = nonSystemMessages.map { message in
            [
                "role": message.role == .assistant ? "assistant" : "user",
                "content": message.content,
            ]
        }

        if !attachments.isEmpty, var last = messages.last, (last["role"] as? String) == MessageRole.user.rawValue {
            var blocks: [[String: Any]] = []
            if let text = last["content"] as? String, !text.isEmpty {
                blocks.append(["type": "text", "text": text])
            }
            for attachment in attachments where isImageMime(attachment.mimeType) {
                let encoded = try store.loadAttachmentData(attachment).base64EncodedString()
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": attachment.mimeType,
                        "data": encoded,
                    ],
                ])
            }
            last["content"] = blocks.isEmpty ? (last["content"] as? String ?? "") : blocks
            messages[messages.count - 1] = last
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if !systemMessages.isEmpty {
            body["system"] = systemMessages.joined(separator: "\n\n")
        }
        if enableThinking {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": max(1024, min(maxTokens, 4096)),
            ]
        }
        return body
    }

    private func buildGeminiBody(
        promptMessages: [PromptMessage],
        attachments: [AttachmentMetadata],
        maxTokens: Int,
        reasoningMode: ReasoningMode,
        model: String
    ) throws -> [String: Any] {
        let systemMessages = promptMessages.filter { $0.role == .system }.map(\.content).filter { !$0.isEmpty }
        let nonSystemMessages = promptMessages.filter { $0.role != .system }

        var contents: [[String: Any]] = nonSystemMessages.map { message in
            [
                "role": geminiRole(for: message.role),
                "parts": [
                    ["text": message.content],
                ],
            ]
        }

        if !attachments.isEmpty, var last = contents.last, (last["role"] as? String) == "user" {
            var parts = (last["parts"] as? [[String: Any]]) ?? []
            for attachment in attachments where canInlineGeminiAttachment(attachment.mimeType) {
                let encoded = try store.loadAttachmentData(attachment).base64EncodedString()
                parts.append([
                    "inline_data": [
                        "mime_type": attachment.mimeType,
                        "data": encoded,
                    ],
                ])
            }
            last["parts"] = parts
            contents[contents.count - 1] = last
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": geminiGenerationConfig(maxTokens: maxTokens, reasoningMode: reasoningMode, model: model),
        ]
        if !systemMessages.isEmpty {
            body["systemInstruction"] = [
                "parts": systemMessages.map { ["text": $0] },
            ]
        }
        return body
    }

    private func buildPrompt(
        conversation: Conversation,
        userContent: String,
        attachmentBlock: String,
        includeLatestMessages: Bool,
        simulationBallast: String
    ) -> [PromptMessage] {
        var messages: [PromptMessage] = []
        messages.append(PromptMessage(role: .system, content: AppDefaults.systemPrompt))
        if !conversation.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(PromptMessage(role: .system, content: "Conversation summary: \(conversation.summary)"))
        }
        var history = recentMessages(conversation.messages)
        if !includeLatestMessages, !history.isEmpty {
            history.removeLast()
        }
        messages.append(contentsOf: history.map { PromptMessage(role: $0.role, content: $0.content) })

        var content = userContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachmentBlock.isEmpty {
            content += "\n\nAttached files:\n\(attachmentBlock)"
        }
        if !simulationBallast.isEmpty {
            content += simulationBallast
        }
        messages.append(PromptMessage(role: .user, content: content))
        return messages
    }

    private func buildSummaryPrompt(conversation: Conversation) -> [PromptMessage] {
        let window = recentMessages(conversation.messages)
        let older = Array(conversation.messages.dropLast(window.count))
        var messages = [PromptMessage(role: .system, content: AppDefaults.summaryPrompt)]
        if !conversation.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(PromptMessage(role: .system, content: "Existing summary: \(conversation.summary)"))
        }
        messages.append(contentsOf: older.map { PromptMessage(role: $0.role, content: $0.content) })
        messages.append(PromptMessage(role: .user, content: "Please summarize the conversation above."))
        return messages
    }

    private func recentMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        Array(messages.suffix(AppDefaults.windowSize))
    }

    private func attachmentsAsPromptBlock(_ attachments: [AttachmentMetadata]) throws -> String {
        try attachments.map(attachmentBlock).joined(separator: "\n\n")
    }

    private func attachmentBlock(_ metadata: AttachmentMetadata) throws -> String {
        let header = "Attachment #\(metadata.attachmentId): \(metadata.filename) (\(metadata.mimeType), \(metadata.sizeBytes) B)\n"
        if isTextMime(metadata.mimeType) {
            let text = try store.loadAttachmentText(metadata)
            return header + "--- BEGIN ATTACHMENT CONTENT ---\n\(text)\n--- END ATTACHMENT CONTENT ---"
        }
        if isImageMime(metadata.mimeType) {
            return header + "--- IMAGE ATTACHMENT ---\nImage content is stored separately; if the backend supports vision it is sent as multimodal input.\n--- END IMAGE ATTACHMENT ---"
        }
        if isVideoMime(metadata.mimeType) {
            return header + "--- VIDEO ATTACHMENT ---\nVideo content is stored separately; if the backend supports video input it is sent as multimodal input.\n--- END VIDEO ATTACHMENT ---"
        }
        return header + "--- BINARY ATTACHMENT METADATA ---\nBinary content is not inlined into the prompt. Use filename, MIME type, and any native backend attachment support.\n--- END BINARY ATTACHMENT METADATA ---"
    }

    private func extractContent(
        from data: Data,
        interfaceType: LLMInterfaceKind,
        maxTokens: Int,
        enableThinking: Bool
    ) throws -> LLMChatResult {
        switch interfaceType {
        case .openAICompatible:
            return try extractOpenAIContent(from: data)
        case .ollama:
            return try extractOllamaContent(from: data)
        case .anthropic:
            return try extractAnthropicContent(from: data, maxTokens: maxTokens, enableThinking: enableThinking)
        case .gemini:
            return try extractGeminiContent(from: data)
        }
    }

    private func extractOpenAIContent(from data: Data) throws -> LLMChatResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError.invalidJSON(L10n.choose("LLM vrátilo neplatný JSON", "LLM returned invalid JSON"))
        }
        let usage = parseUsage(from: json)
        if let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
            let message = (choice["message"] as? [String: Any]) ?? choice
            let content = text(from: message["content"])
            if !content.isEmpty {
                return LLMChatResult(text: content, usage: usage)
            }
            let reasoning = text(from: message["reasoning"]).isEmpty ? text(from: message["reasoning_content"]) : text(from: message["reasoning"])
            if !reasoning.isEmpty {
                if (choice["finish_reason"] as? String) == "length" {
                    return LLMChatResult(
                        text: reasoning + "\n\n[\(L10n.choose("Model vyčerpal limit tokenů během myšlení, takže finální odpověď nedokončil. Zkus vypnout Myšlení nebo zvýšit max_tokens.", "The model used up the token limit while thinking, so the final answer was not completed. Try turning Thinking off or increasing max_tokens."))]",
                        usage: usage
                    )
                }
                return LLMChatResult(text: reasoning, usage: usage)
            }
        }
        if let message = json["message"] as? [String: Any] {
            let content = text(from: message["content"])
            if !content.isEmpty {
                return LLMChatResult(text: content, usage: usage)
            }
        }
        let content = text(from: json["content"])
        if !content.isEmpty {
            return LLMChatResult(text: content, usage: usage)
        }
        let reasoning = text(from: json["reasoning"])
        if !reasoning.isEmpty {
            return LLMChatResult(text: reasoning, usage: usage)
        }
        throw LLMServiceError.invalidResponse
    }

    private func extractOllamaContent(from data: Data) throws -> LLMChatResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError.invalidJSON(L10n.choose("LLM vrátilo neplatný JSON", "LLM returned invalid JSON"))
        }

        let message = json["message"] as? [String: Any]
        let content = text(from: message?["content"])
        let thinking = text(from: message?["thinking"])
        let responseText = !content.isEmpty ? content : thinking
        guard !responseText.isEmpty else {
            throw LLMServiceError.invalidResponse
        }

        let promptTokens = json["prompt_eval_count"] as? Int
        let completionTokens = json["eval_count"] as? Int
        let totalTokens: Int?
        if let promptTokens, let completionTokens {
            totalTokens = promptTokens + completionTokens
        } else {
            totalTokens = nil
        }

        return LLMChatResult(
            text: responseText,
            usage: LLMUsageMetrics(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens
            )
        )
    }

    private func extractAnthropicContent(from data: Data, maxTokens: Int, enableThinking: Bool) throws -> LLMChatResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError.invalidJSON(L10n.choose("LLM vrátilo neplatný JSON", "LLM returned invalid JSON"))
        }

        let blocks = (json["content"] as? [[String: Any]]) ?? []
        let textBlocks = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
        let thinkingBlocks = blocks.filter { ($0["type"] as? String) == "thinking" }.compactMap { $0["thinking"] as? String }
        let visibleText = textBlocks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = thinkingBlocks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let usageObject = json["usage"] as? [String: Any]
        let promptTokens = usageObject?["input_tokens"] as? Int
        let completionTokens = usageObject?["output_tokens"] as? Int
        let totalTokens: Int?
        if let promptTokens, let completionTokens {
            totalTokens = promptTokens + completionTokens
        } else {
            totalTokens = nil
        }

        if !visibleText.isEmpty {
            return LLMChatResult(
                text: visibleText,
                usage: LLMUsageMetrics(promptTokens: promptTokens, completionTokens: completionTokens, totalTokens: totalTokens)
            )
        }
        if !reasoning.isEmpty {
            let stopReason = json["stop_reason"] as? String
            let suffix = stopReason == "max_tokens"
                ? "\n\n[\(L10n.choose("Model vyčerpal limit tokenů během myšlení, takže finální odpověď nedokončil. Zkus vypnout Myšlení nebo zvýšit max_tokens.", "The model used up the token limit while thinking, so the final answer was not completed. Try turning Thinking off or increasing max_tokens."))]"
                : ""
            return LLMChatResult(
                text: reasoning + suffix,
                usage: LLMUsageMetrics(promptTokens: promptTokens, completionTokens: completionTokens, totalTokens: totalTokens)
            )
        }
        throw LLMServiceError.invalidResponse
    }

    private func extractGeminiContent(from data: Data) throws -> LLMChatResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError.invalidJSON(L10n.choose("LLM vrátilo neplatný JSON", "LLM returned invalid JSON"))
        }

        let candidates = (json["candidates"] as? [[String: Any]]) ?? []
        let firstCandidate = candidates.first
        let content = firstCandidate?["content"] as? [String: Any]
        let parts = (content?["parts"] as? [[String: Any]]) ?? []
        let textValue = parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textValue.isEmpty else {
            throw LLMServiceError.invalidResponse
        }

        let usage = json["usageMetadata"] as? [String: Any]
        return LLMChatResult(
            text: textValue,
            usage: LLMUsageMetrics(
                promptTokens: usage?["promptTokenCount"] as? Int,
                completionTokens: usage?["candidatesTokenCount"] as? Int,
                totalTokens: usage?["totalTokenCount"] as? Int
            )
        )
    }

    private func text(from value: Any?) -> String {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let list as [Any]:
            return list.compactMap { item -> String? in
                if let string = item as? String {
                    return string
                }
                guard let dictionary = item as? [String: Any] else {
                    return nil
                }
                if let text = dictionary["text"] as? String {
                    return text
                }
                if let nested = dictionary["content"] as? String {
                    return nested
                }
                return nil
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return ""
        }
    }

    private func decodeStreamLine(_ rawLine: String, interfaceType: LLMInterfaceKind) throws -> [LLMEvent] {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return [] }
        let payload: String
        if trimmed.hasPrefix("data:") {
            payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else if trimmed.hasPrefix("event:") {
            return []
        } else {
            payload = trimmed
        }
        guard payload != "[DONE]" else { return [.completed(finishReason: nil)] }
        guard let data = payload.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw LLMServiceError.invalidJSON(L10n.choose("Stream obsahuje neplatný JSON.", "The stream contains invalid JSON."))
        }

        switch interfaceType {
        case .openAICompatible:
            return openAIStreamEvents(json)
        case .ollama:
            return ollamaStreamEvents(json)
        case .anthropic:
            return anthropicStreamEvents(json)
        case .gemini:
            return geminiStreamEvents(json)
        }
    }

    private func openAIStreamEvents(_ json: [String: Any]) -> [LLMEvent] {
        var events: [LLMEvent] = []
        if let choice = (json["choices"] as? [[String: Any]])?.first {
            let delta = (choice["delta"] as? [String: Any]) ?? [:]
            if let reasoning = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String), !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.textDelta(content))
            }
            if let finish = choice["finish_reason"] as? String {
                events.append(.completed(finishReason: finish))
            }
        }
        if json["usage"] is [String: Any] {
            events.append(.usage(parseUsage(from: json)))
        }
        return events
    }

    private func ollamaStreamEvents(_ json: [String: Any]) -> [LLMEvent] {
        var events: [LLMEvent] = []
        let message = json["message"] as? [String: Any]
        if let thinking = message?["thinking"] as? String, !thinking.isEmpty {
            events.append(.reasoningDelta(thinking))
        }
        if let content = message?["content"] as? String, !content.isEmpty {
            events.append(.textDelta(content))
        }
        if let prompt = json["prompt_eval_count"] as? Int ?? json["prompt_count"] as? Int,
           let completion = json["eval_count"] as? Int ?? json["generation_count"] as? Int {
            events.append(.usage(LLMUsageMetrics(promptTokens: prompt, completionTokens: completion, totalTokens: prompt + completion)))
        }
        if (json["done"] as? Bool) == true {
            events.append(.completed(finishReason: json["done_reason"] as? String))
        }
        return events
    }

    private func anthropicStreamEvents(_ json: [String: Any]) -> [LLMEvent] {
        var events: [LLMEvent] = []
        let type = json["type"] as? String
        if type == "content_block_delta", let delta = json["delta"] as? [String: Any] {
            if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                events.append(.reasoningDelta(thinking))
            }
            if let text = delta["text"] as? String, !text.isEmpty {
                events.append(.textDelta(text))
            }
        }
        if type == "message_start",
           let message = json["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            events.append(.usage(LLMUsageMetrics(
                promptTokens: usage["input_tokens"] as? Int,
                completionTokens: usage["output_tokens"] as? Int,
                totalTokens: nil
            )))
        }
        if type == "message_delta" {
            let usage = json["usage"] as? [String: Any]
            events.append(.usage(LLMUsageMetrics(
                promptTokens: nil,
                completionTokens: usage?["output_tokens"] as? Int,
                totalTokens: nil
            )))
            let delta = json["delta"] as? [String: Any]
            events.append(.completed(finishReason: delta?["stop_reason"] as? String))
        }
        return events
    }

    private func geminiStreamEvents(_ json: [String: Any]) -> [LLMEvent] {
        var events: [LLMEvent] = []
        if let candidate = (json["candidates"] as? [[String: Any]])?.first {
            let content = candidate["content"] as? [String: Any]
            let parts = (content?["parts"] as? [[String: Any]]) ?? []
            for part in parts {
                guard let text = part["text"] as? String, !text.isEmpty else { continue }
                if (part["thought"] as? Bool) == true {
                    events.append(.reasoningDelta(text))
                } else {
                    events.append(.textDelta(text))
                }
            }
            if let finish = candidate["finishReason"] as? String {
                events.append(.completed(finishReason: finish))
            }
        }
        if let usage = json["usageMetadata"] as? [String: Any] {
            events.append(.usage(LLMUsageMetrics(
                promptTokens: usage["promptTokenCount"] as? Int,
                completionTokens: usage["candidatesTokenCount"] as? Int,
                totalTokens: usage["totalTokenCount"] as? Int
            )))
        }
        return events
    }

    private func merging(_ previous: LLMUsageMetrics, with update: LLMUsageMetrics) -> LLMUsageMetrics {
        let prompt = update.promptTokens ?? previous.promptTokens
        let completion = update.completionTokens ?? previous.completionTokens
        let total = update.totalTokens ?? previous.totalTokens ?? {
            guard let prompt, let completion else { return nil }
            return prompt + completion
        }()
        return LLMUsageMetrics(promptTokens: prompt, completionTokens: completion, totalTokens: total)
    }

    private func streamingChatURL(baseURL: String, interfaceType: LLMInterfaceKind, model: String) throws -> URL {
        guard interfaceType == .gemini else {
            return try chatURL(baseURL: baseURL, interfaceType: interfaceType, model: model)
        }
        guard var components = URLComponents(url: try geminiGenerateContentURL(baseURL: baseURL, model: model), resolvingAgainstBaseURL: false) else {
            throw LLMServiceError.invalidConfiguration(L10n.choose("Neplatná Gemini stream URL", "Invalid Gemini stream URL"))
        }
        let streamingPath = components.path.replacingOccurrences(of: ":generateContent", with: ":streamGenerateContent")
        components.path = streamingPath
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        guard let url = components.url else {
            throw LLMServiceError.invalidConfiguration(L10n.choose("Neplatná Gemini stream URL", "Invalid Gemini stream URL"))
        }
        return url
    }

    private func chatURL(baseURL: String, interfaceType: LLMInterfaceKind, model: String) throws -> URL {
        switch interfaceType {
        case .openAICompatible:
            return try endpointURL(baseURL: baseURL, endpointSegments: ["chat", "completions"], versionSegment: "v1")
        case .ollama:
            return try endpointURL(baseURL: baseURL, endpointSegments: ["chat"], versionSegment: "api")
        case .anthropic:
            return try endpointURL(baseURL: baseURL, endpointSegments: ["messages"], versionSegment: "v1")
        case .gemini:
            return try geminiGenerateContentURL(baseURL: baseURL, model: model)
        }
    }

    private func modelsURL(baseURL: String, interfaceType: LLMInterfaceKind) throws -> URL {
        switch interfaceType {
        case .openAICompatible:
            return try endpointURL(baseURL: baseURL, endpointSegments: ["models"], versionSegment: "v1")
        case .ollama:
            return try endpointURL(baseURL: baseURL, endpointSegments: ["tags"], versionSegment: "api")
        case .anthropic:
            return try endpointURL(baseURL: baseURL, endpointSegments: ["models"], versionSegment: "v1")
        case .gemini:
            return try endpointURL(baseURL: baseURL, endpointSegments: ["models"], versionSegment: "v1beta")
        }
    }

    private func endpointURL(baseURL: String, endpointSegments: [String], versionSegment: String) throws -> URL {
        var components = try normalizedBaseURLComponents(baseURL)
        var pathSegments = components.path.split(separator: "/").map(String.init)

        if pathSegments.suffix(2) == ["chat", "completions"] {
            pathSegments.removeLast(2)
        } else if let last = pathSegments.last, ["models", "messages", "tags", "chat"].contains(last) {
            pathSegments.removeLast()
        }

        if pathSegments.last != versionSegment {
            if pathSegments.last == "v1" || pathSegments.last == "v1beta" || pathSegments.last == "api" {
                pathSegments.removeLast()
            }
            pathSegments.append(versionSegment)
        }

        pathSegments.append(contentsOf: endpointSegments)
        components.path = "/" + pathSegments.joined(separator: "/")

        guard let url = components.url else {
            throw LLMServiceError.invalidConfiguration(
                L10n.choose(
                    "Neplatná LLM URL: \(baseURL)",
                    "Invalid LLM URL: \(baseURL)"
                )
            )
        }
        return url
    }

    private func geminiGenerateContentURL(baseURL: String, model: String) throws -> URL {
        var components = try normalizedBaseURLComponents(baseURL)
        var pathSegments = components.path.split(separator: "/").map(String.init)

        if let last = pathSegments.last, last.contains(":generateContent") {
            pathSegments.removeLast()
        }

        if pathSegments.last != "v1beta" {
            if pathSegments.last == "v1" || pathSegments.last == "models" {
                pathSegments.removeLast()
            }
            pathSegments.append("v1beta")
        }

        let normalizedModel = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        pathSegments.append("models")
        pathSegments.append("\(normalizedModel):generateContent")
        components.path = "/" + pathSegments.joined(separator: "/")

        guard let url = components.url else {
            throw LLMServiceError.invalidConfiguration(
                L10n.choose("Neplatná LLM URL: \(baseURL)", "Invalid LLM URL: \(baseURL)")
            )
        }
        return url
    }

    private func normalizedBaseURLComponents(_ baseURL: String) throws -> URLComponents {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMServiceError.invalidConfiguration(L10n.choose("Chybí LLM URL", "Missing LLM URL"))
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw LLMServiceError.invalidConfiguration(
                L10n.choose(
                    "Neplatná LLM URL: \(trimmed)",
                    "Invalid LLM URL: \(trimmed)"
                )
            )
        }

        components.scheme = scheme
        if components.path != "/" {
            components.path = "/" + components.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            components.path = ""
        }
        return components
    }

    private func parseProbeResponse(data: Data, settings: AppSettings, url: URL) throws -> LLMStatus {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError.invalidJSON(L10n.choose("LLM vrátilo neplatný JSON", "LLM returned invalid JSON"))
        }

        let modelIDs: [String]
        let maxModelLen: Int?

        switch settings.interfaceType {
        case .openAICompatible:
            let models = (json["data"] as? [[String: Any]]) ?? []
            modelIDs = models.compactMap { $0["id"] as? String }
            maxModelLen = models.first(where: { ($0["id"] as? String) == settings.model })?["max_model_len"] as? Int
        case .ollama:
            let models = (json["models"] as? [[String: Any]]) ?? []
            modelIDs = models.compactMap { ($0["model"] as? String) ?? ($0["name"] as? String) }
            maxModelLen = nil
        case .anthropic:
            let models = (json["data"] as? [[String: Any]]) ?? []
            modelIDs = models.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            maxModelLen = nil
        case .gemini:
            let models = (json["models"] as? [[String: Any]]) ?? []
            modelIDs = models.compactMap {
                if let name = $0["name"] as? String {
                    return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
                }
                return nil
            }
            if let selected = models.first(where: {
                let name = (($0["name"] as? String) ?? "")
                return name == settings.model || name == "models/\(settings.model)"
            }) {
                maxModelLen = selected["inputTokenLimit"] as? Int
            } else {
                maxModelLen = nil
            }
        }

        let normalizedModel = settings.model.hasPrefix("models/") ? String(settings.model.dropFirst("models/".count)) : settings.model
        let exists = modelIDs.isEmpty || modelIDs.contains(normalizedModel) || modelIDs.contains(settings.model)

        return LLMStatus(
            ok: exists,
            url: url.absoluteString,
            model: settings.model,
            maxModelLen: maxModelLen,
            availableModels: modelIDs,
            message: exists
                ? L10n.choose("Model je dostupný.", "Model is available.")
                : L10n.choose("Endpoint je dostupný, ale model nebyl nalezen.", "The endpoint is reachable, but the model was not found.")
        )
    }

    private func applyHeaders(to request: inout URLRequest, settings: AppSettings, includeContentType: Bool) {
        if includeContentType {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        switch settings.interfaceType {
        case .openAICompatible:
            if !settings.apiKey.isEmpty {
                request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .ollama:
            if !settings.apiKey.isEmpty {
                request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            if !settings.apiKey.isEmpty {
                request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            if !settings.apiKey.isEmpty {
                request.setValue(settings.apiKey, forHTTPHeaderField: "x-goog-api-key")
            }
        }
    }

    private func geminiGenerationConfig(maxTokens: Int, reasoningMode: ReasoningMode, model: String) -> [String: Any] {
        var config: [String: Any] = ["maxOutputTokens": maxTokens]
        if model.lowercased().contains("gemini-3") {
            config["thinkingConfig"] = [
                "thinkingLevel": reasoningMode == .high ? "HIGH" : "LOW",
            ]
        } else {
            config["thinkingConfig"] = [
                "thinkingBudget": reasoningMode == .off ? 0 : (reasoningMode == .low ? 1_024 : -1),
            ]
        }
        return config
    }

    private func geminiRole(for role: MessageRole) -> String {
        role == .assistant ? "model" : "user"
    }

    private func canInlineGeminiAttachment(_ mimeType: String) -> Bool {
        isImageMime(mimeType) || isVideoMime(mimeType) || mimeType.hasPrefix("audio/") || mimeType == "application/pdf"
    }

    private func isTextMime(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("text/") || ["application/json", "application/xml", "text/xml", "application/javascript"].contains(mimeType)
    }

    private func isImageMime(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("image/")
    }

    private func isVideoMime(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("video/")
    }

    private func requestErrorDescription(_ error: Error, url: String) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return L10n.choose("LLM neodpovědělo v limitu na \(url)", "LLM did not respond in time at \(url)")
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return L10n.choose("Nepodařilo se připojit k \(url)", "Could not connect to \(url)")
            default:
                return L10n.choose("Chyba HTTP požadavku na \(url): \(nsError.localizedDescription)", "HTTP request error for \(url): \(nsError.localizedDescription)")
            }
        }
        return nsError.localizedDescription
    }

    private func logRequest(label: String, url: URL, headers: [String: String], body: [String: Any]?) {
        var lines = [
            ">>> \(timestamp()) REQUEST [\(label.uppercased())]",
            "URL: \(url.absoluteString)",
            "Headers: \(prettyHeaders(headers))",
        ]
        if let body {
            lines.append("Body:")
            lines.append(prettyJSONObject(sanitized(body)))
        }
        log(lines.joined(separator: "\n"))
    }

    private func logResponse(label: String, url: URL, status: Int, data: Data, apiKey: String) {
        let bodyText: String
        if let json = try? JSONSerialization.jsonObject(with: data) {
            bodyText = redactedText(prettyJSONObject(sanitized(json)), apiKey: apiKey)
        } else {
            bodyText = redactedText(String(data: data, encoding: .utf8) ?? "<binarni odpoved>", apiKey: apiKey)
        }
        log(
            [
                "<<< \(timestamp()) RESPONSE [\(label.uppercased())]",
                "URL: \(url.absoluteString)",
                "Status: \(status)",
                "Body:",
                bodyText,
            ].joined(separator: "\n")
        )
    }

    private func logError(label: String, url: URL?, error: String) {
        var lines = ["xxx \(timestamp()) ERROR [\(label.uppercased())]"]
        if let url {
            lines.append("URL: \(url.absoluteString)")
        }
        lines.append("Detail: \(error)")
        log(lines.joined(separator: "\n"))
    }

    private func log(_ entry: String) {
        onDebugEvent?(entry + "\n\n")
    }

    private func prettyHeaders(_ headers: [String: String]) -> String {
        let secretHeaders = Set(["authorization", "x-api-key", "x-goog-api-key", "api-key"])
        let masked = Dictionary(uniqueKeysWithValues: headers.map { key, value in
            let replacement = secretHeaders.contains(key.lowercased())
                ? (value.lowercased().hasPrefix("bearer ") ? "Bearer ****" : "****")
                : value
            return (key, replacement)
        })
        if let data = try? JSONSerialization.data(withJSONObject: masked, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return masked.description
    }

    private func prettyJSONObject(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private func sanitized(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var sanitizedDictionary: [String: Any] = [:]
            for (key, nested) in dictionary {
                let normalizedKey = key.lowercased()
                if ["authorization", "api_key", "apikey", "x-api-key", "x-goog-api-key"].contains(normalizedKey) {
                    sanitizedDictionary[key] = "****"
                } else if key == "url",
                   let string = nested as? String,
                   string.hasPrefix("data:") {
                    sanitizedDictionary[key] = shortenedDataURL(string)
                } else {
                    sanitizedDictionary[key] = sanitized(nested)
                }
            }
            return sanitizedDictionary
        }
        if let list = value as? [Any] {
            return list.map { sanitized($0) }
        }
        if let string = value as? String, string.count > 1_200 {
            let prefix = string.prefix(1_200)
            return "\(prefix)... [truncated, \(string.count) chars]"
        }
        return value
    }

    private func shortenedDataURL(_ value: String) -> String {
        let prefix = value.prefix(48)
        return "\(prefix)... [data omitted, \(value.count) chars]"
    }

    private func redactedText(_ value: String, apiKey: String) -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return value }
        return value.replacingOccurrences(of: key, with: "****")
    }

    private func estimateInputTokens(_ messages: [PromptMessage]) -> Int {
        let characters = messages.reduce(0) { partial, message in
            partial + message.role.rawValue.count + message.content.count + 8
        }
        return max(1, Int(ceil(Double(characters) / 4.0)))
    }

    private func simulationBallastText(enabled: Bool, maxTokens: Int) -> String {
        guard enabled else { return "" }
        let tokenTarget = max(maxTokens * 3, 4_096)
        let payload = String(repeating: " ballast-token", count: tokenTarget)
        return "\n\n[SIMULATION]\n\(payload)"
    }

    private func parseUsage(from json: [String: Any]) -> LLMUsageMetrics {
        let usage = json["usage"] as? [String: Any]
        return LLMUsageMetrics(
            promptTokens: usage?["prompt_tokens"] as? Int,
            completionTokens: usage?["completion_tokens"] as? Int,
            totalTokens: usage?["total_tokens"] as? Int
        )
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

enum LLMServiceError: LocalizedError {
    case invalidConfiguration(String)
    case request(String)
    case http(status: Int, body: String, url: String)
    case invalidJSON(String)
    case invalidResponse
    case structuredOutput(job: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            return message
        case let .request(message):
            return message
        case let .http(status, body, url):
            return L10n.choose(
                "LLM HTTP \(status) na \(url): \(String(body.prefix(400)))",
                "LLM HTTP \(status) at \(url): \(String(body.prefix(400)))"
            )
        case let .invalidJSON(message):
            return message
        case .invalidResponse:
            return L10n.choose("Neznámý formát odpovědi LLM", "Unknown LLM response format")
        case let .structuredOutput(job, detail):
            return L10n.choose(
                "Strukturovaný výstup \(job) není platný: \(detail)",
                "Structured output \(job) is invalid: \(detail)"
            )
        }
    }
}
