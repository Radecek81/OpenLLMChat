import Foundation

enum AppDefaults {
    static let appName = "Open LLM chat"
    static let supportDirectoryName = "LLM Chat Swift"
    static let systemPrompt = "You are a concise local assistant. Keep responses short but helpful."
    static let summaryPrompt = "Summarize the conversation so far. Keep key decisions, tasks, and any files that were referenced by name. Do not include small talk. Be under 120 words."
    static let windowSize = 10
    static let summaryTrigger = 18
    static let summaryMinMessages = 8
    static let maxAttachments = 3
    static let maxFileSizeBytes = 10 * 1024 * 1024
    static let maxTextInPromptPerFile = 12_000
    static let maxTokens = 4_096
    static let maxTokensThinking = 8_192
    static let requestTimeout: TimeInterval = 900
    static let baseURL = ""
    static let model = ""
    static let apiKey = ""
    static let defaultCompressionThresholdPercent = 70
    static let defaultKnownMaxModelLen = 32_768
}



enum AttachmentRules {
    static let allowedExactMimeTypes: Set<String> = [
        "application/json",
        "application/xml",
        "text/xml",
        "application/javascript",
        "application/pdf",
        "application/msword",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "audio/mpeg",
        "audio/mp3",
        "audio/wav",
        "audio/x-wav",
        "video/mp4",
        "video/x-msvideo",
    ]

    static func isAllowed(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("text/") ||
            mimeType.hasPrefix("image/") ||
            mimeType.hasPrefix("audio/") ||
            mimeType.hasPrefix("video/") ||
            allowedExactMimeTypes.contains(mimeType)
    }
}

func formatBytes(_ bytes: Int) -> String {
    guard bytes > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB"]
    let value = Double(bytes)
    let index = min(Int(log(value) / log(1024.0)), units.count - 1)
    let scaled = value / pow(1024.0, Double(index))
    return String(format: "%.1f %@", scaled, units[index])
}

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

enum MessageContentPartKind: String, Codable, Hashable {
    case text
    case reasoning
    case image
    case audio
    case video
    case file
    case citation
    case toolCall
    case toolResult
    case status
    case error
}

struct MessageContentPart: Codable, Hashable, Identifiable {
    var id: String
    var kind: MessageContentPartKind
    var text: String
    var metadata: [String: String]?

    init(id: String = UUID().uuidString, kind: MessageContentPartKind, text: String, metadata: [String: String]? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.metadata = metadata
    }
}

struct AttachmentMetadata: Codable, Hashable, Identifiable {
    let attachmentId: String
    var filename: String
    var mimeType: String
    var sizeBytes: Int
    var storedPath: String
    var sha256: String

    var id: String { attachmentId }

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case filename
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case storedPath = "stored_path"
        case sha256
    }
}

struct PendingAttachment: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let data: Data
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var messageId: String
    var role: MessageRole
    var content: String
    var parts: [MessageContentPart]
    var attachments: [AttachmentMetadata]
    var ts: String
    var status: String?
    var endpointId: String?
    var requestId: String?
    var usage: LLMUsageMetrics?
    var latencyMs: Int?
    var finishReason: String?

    var id: String { messageId }

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case role
        case content
        case parts
        case attachments
        case ts
        case status
        case endpointId = "endpoint_id"
        case requestId = "request_id"
        case usage
        case latencyMs = "latency_ms"
        case finishReason = "finish_reason"
    }

    init(
        messageId: String = UUID().uuidString,
        role: MessageRole,
        content: String,
        parts: [MessageContentPart]? = nil,
        attachments: [AttachmentMetadata],
        ts: String,
        status: String?,
        endpointId: String? = nil,
        requestId: String? = nil,
        usage: LLMUsageMetrics? = nil,
        latencyMs: Int? = nil,
        finishReason: String? = nil
    ) {
        self.messageId = messageId
        self.role = role
        self.content = content
        self.parts = parts ?? (content.isEmpty ? [] : [MessageContentPart(kind: .text, text: content)])
        self.attachments = attachments
        self.ts = ts
        self.status = status
        self.endpointId = endpointId
        self.requestId = requestId
        self.usage = usage
        self.latencyMs = latencyMs
        self.finishReason = finishReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        parts = try container.decodeIfPresent([MessageContentPart].self, forKey: .parts)
            ?? (content.isEmpty ? [] : [MessageContentPart(kind: .text, text: content)])
        attachments = try container.decodeIfPresent([AttachmentMetadata].self, forKey: .attachments) ?? []
        ts = try container.decodeIfPresent(String.self, forKey: .ts) ?? Date.timestamp
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
            ?? "\(role.rawValue)-\(ts)"
        status = try container.decodeIfPresent(String.self, forKey: .status)
        endpointId = try container.decodeIfPresent(String.self, forKey: .endpointId)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        usage = try container.decodeIfPresent(LLMUsageMetrics.self, forKey: .usage)
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
        finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
    }

    var reasoning: String {
        parts.filter { $0.kind == .reasoning }.map(\.text).joined()
    }

    mutating func replaceStreamedContent(text: String, reasoning: String) {
        content = text
        parts = []
        if !reasoning.isEmpty {
            parts.append(MessageContentPart(kind: .reasoning, text: reasoning))
        }
        if !text.isEmpty {
            parts.append(MessageContentPart(kind: .text, text: text))
        }
    }
}

struct Conversation: Codable, Identifiable, Hashable {
    var id: String
    var createdAt: String
    var updatedAt: String
    var summary: String
    var generatedTitle: String?
    var messages: [ChatMessage]
    var files: [AttachmentMetadata]

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case summary
        case generatedTitle = "generated_title"
        case messages
        case files
    }

    init(id: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""), createdAt: String = Date.timestamp, updatedAt: String? = nil, summary: String = "", generatedTitle: String? = nil, messages: [ChatMessage] = [], files: [AttachmentMetadata] = []) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.summary = summary
        self.generatedTitle = generatedTitle
        self.messages = messages
        self.files = files
    }

    var title: String {
        if let generatedTitle, !generatedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(generatedTitle.prefix(64))
        }
        if let firstUser = messages.first(where: { $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return String(firstUser.content.prefix(48))
        }
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(summary.prefix(48))
        }
        return L10n.choose("Nový chat", "New chat")
    }

    var preview: String {
        guard let last = messages.last else { return L10n.choose("Bez zpráv", "No messages") }
        let trimmed = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.choose("Bez textu", "No text") : String(trimmed.prefix(72))
    }

    var messageCount: Int { messages.count }
}

enum ReasoningMode: String, Codable, CaseIterable, Identifiable {
    case off
    case low
    case high

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .off: return L10n.choose("Vypnuto", "Off")
        case .low: return L10n.choose("Nízké", "Low")
        case .high: return L10n.choose("Vysoké", "High")
        }
    }
}

enum LLMInterfaceKind: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai_compatible"
    case ollama = "ollama"
    case anthropic = "anthropic"
    case gemini = "gemini"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .openAICompatible:
            return L10n.choose("GPT kompatibilní", "GPT compatible")
        case .ollama:
            return "Ollama"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Gemini"
        }
    }
}

struct EndpointCapabilities: Codable, Hashable {
    var supportsTextChat: Bool
    var supportsModelList: Bool?
    var maxContextTokens: Int?
    var lastProbeOK: Bool?
    var lastProbeAt: String?

    static let unknown = EndpointCapabilities(
        supportsTextChat: true,
        supportsModelList: nil,
        maxContextTokens: nil,
        lastProbeOK: nil,
        lastProbeAt: nil
    )
}

struct RoutePolicy: Codable, Hashable {
    var automaticFallbackEnabled: Bool
    var circuitFailureThreshold: Int
    var circuitCooldownSeconds: Int

    static let `default` = RoutePolicy(
        automaticFallbackEnabled: false,
        circuitFailureThreshold: 2,
        circuitCooldownSeconds: 60
    )
}

struct LLMConnectionProfile: Codable, Hashable, Identifiable {
    var id: String
    var baseURL: String
    var model: String
    var credentialID: String
    var apiKeyHint: String
    var interfaceType: LLMInterfaceKind
    var capabilities: EndpointCapabilities
    var legacyAPIKey: String?

    enum CodingKeys: String, CodingKey {
        case id
        case baseURL
        case model
        case credentialID
        case apiKeyHint
        case interfaceType
        case capabilities
        case apiKey
    }

    init(
        id: String = UUID().uuidString,
        baseURL: String,
        model: String,
        credentialID: String = UUID().uuidString,
        apiKeyHint: String = "",
        interfaceType: LLMInterfaceKind,
        capabilities: EndpointCapabilities = .unknown
    ) {
        self.id = id
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentialID = credentialID
        self.apiKeyHint = apiKeyHint
        self.interfaceType = interfaceType
        self.capabilities = capabilities
        legacyAPIKey = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        credentialID = try container.decodeIfPresent(String.self, forKey: .credentialID) ?? id
        interfaceType = try container.decodeIfPresent(LLMInterfaceKind.self, forKey: .interfaceType) ?? .openAICompatible
        capabilities = try container.decodeIfPresent(EndpointCapabilities.self, forKey: .capabilities) ?? .unknown
        legacyAPIKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        apiKeyHint = try container.decodeIfPresent(String.self, forKey: .apiKeyHint)
            ?? Self.maskedHint(for: legacyAPIKey ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(credentialID, forKey: .credentialID)
        try container.encode(apiKeyHint, forKey: .apiKeyHint)
        try container.encode(interfaceType, forKey: .interfaceType)
        try container.encode(capabilities, forKey: .capabilities)
    }

    var title: String {
        model.isEmpty ? baseURL : model
    }

    var subtitle: String {
        var parts = [baseURL, interfaceType.localizedTitle]
        let masked = maskedAPIKey
        if !masked.isEmpty {
            parts.append(masked)
        }
        return parts.joined(separator: " · ")
    }

    var maskedAPIKey: String {
        apiKeyHint.isEmpty ? L10n.choose("bez klíče", "no API key") : apiKeyHint
    }

    static func maskedHint(for apiKey: String) -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "••••\(trimmed.suffix(min(4, trimmed.count)))"
    }

    func matches(
        baseURL: String,
        model: String,
        interfaceType: LLMInterfaceKind
    ) -> Bool {
        self.baseURL.caseInsensitiveCompare(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame &&
            self.model.caseInsensitiveCompare(model.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame &&
            self.interfaceType == interfaceType
    }
}

struct AppSettings: Codable {
    var schemaVersion: Int
    var baseURL: String
    var model: String
    var apiKey: String
    var interfaceType: LLMInterfaceKind
    var reasoningMode: ReasoningMode
    var maxTokens: Int
    var compressionEnabled: Bool
    var compressionThresholdPercent: Int
    var simulateContextFill: Bool
    var profiles: [LLMConnectionProfile]
    var routePolicy: RoutePolicy
    var advancedFeatures: AdvancedFeatureSettings

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case baseURL
        case model
        case apiKey
        case interfaceType
        case enableThinking
        case reasoningMode
        case maxTokens
        case compressionEnabled
        case compressionThresholdPercent
        case simulateContextFill
        case profiles
        case routePolicy
        case advancedFeatures
        case savedBaseURLs
        case savedModels
    }

    static let `default` = AppSettings(
        schemaVersion: 4,
        baseURL: AppDefaults.baseURL,
        model: AppDefaults.model,
        apiKey: AppDefaults.apiKey,
        interfaceType: .openAICompatible,
        enableThinking: false,
        maxTokens: AppDefaults.maxTokens,
        compressionEnabled: false,
        compressionThresholdPercent: AppDefaults.defaultCompressionThresholdPercent,
        simulateContextFill: false,
        profiles: [],
        routePolicy: .default,
        advancedFeatures: .default
    )

    init(
        schemaVersion: Int,
        baseURL: String,
        model: String,
        apiKey: String,
        interfaceType: LLMInterfaceKind,
        enableThinking: Bool,
        maxTokens: Int,
        compressionEnabled: Bool,
        compressionThresholdPercent: Int,
        simulateContextFill: Bool,
        profiles: [LLMConnectionProfile],
        routePolicy: RoutePolicy,
        advancedFeatures: AdvancedFeatureSettings = .default
    ) {
        self.schemaVersion = schemaVersion
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.interfaceType = interfaceType
        reasoningMode = enableThinking ? .high : .off
        self.maxTokens = maxTokens
        self.compressionEnabled = compressionEnabled
        self.compressionThresholdPercent = compressionThresholdPercent
        self.simulateContextFill = simulateContextFill
        self.profiles = profiles
        self.routePolicy = routePolicy
        self.advancedFeatures = advancedFeatures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? AppDefaults.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? AppDefaults.model
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? AppDefaults.apiKey
        interfaceType = try container.decodeIfPresent(LLMInterfaceKind.self, forKey: .interfaceType) ?? .openAICompatible
        let legacyThinking = try container.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? false
        reasoningMode = try container.decodeIfPresent(ReasoningMode.self, forKey: .reasoningMode)
            ?? (legacyThinking ? .high : .off)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? AppDefaults.maxTokens
        compressionEnabled = try container.decodeIfPresent(Bool.self, forKey: .compressionEnabled) ?? false
        compressionThresholdPercent = try container.decodeIfPresent(Int.self, forKey: .compressionThresholdPercent) ?? AppDefaults.defaultCompressionThresholdPercent
        simulateContextFill = try container.decodeIfPresent(Bool.self, forKey: .simulateContextFill) ?? false
        profiles = try container.decodeIfPresent([LLMConnectionProfile].self, forKey: .profiles) ?? []
        routePolicy = try container.decodeIfPresent(RoutePolicy.self, forKey: .routePolicy) ?? .default
        advancedFeatures = try container.decodeIfPresent(AdvancedFeatureSettings.self, forKey: .advancedFeatures) ?? .default

        if profiles.isEmpty {
            let legacyBaseURLs = try container.decodeIfPresent([String].self, forKey: .savedBaseURLs) ?? []
            let legacyModels = try container.decodeIfPresent([String].self, forKey: .savedModels) ?? []

            if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var current = LLMConnectionProfile(
                    baseURL: baseURL,
                    model: model,
                    apiKeyHint: LLMConnectionProfile.maskedHint(for: apiKey),
                    interfaceType: interfaceType
                )
                current.legacyAPIKey = apiKey
                profiles = [current]
            }

            for legacyBaseURL in legacyBaseURLs where !legacyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let candidate = LLMConnectionProfile(
                    baseURL: legacyBaseURL,
                    model: model,
                    apiKeyHint: LLMConnectionProfile.maskedHint(for: apiKey),
                    interfaceType: interfaceType
                )
                if !profiles.contains(where: { $0.matches(baseURL: candidate.baseURL, model: candidate.model, interfaceType: candidate.interfaceType) }) {
                    var migrated = candidate
                    migrated.legacyAPIKey = apiKey
                    profiles.append(migrated)
                }
            }

            for legacyModel in legacyModels where !legacyModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let candidate = LLMConnectionProfile(
                    baseURL: baseURL,
                    model: legacyModel,
                    apiKeyHint: LLMConnectionProfile.maskedHint(for: apiKey),
                    interfaceType: interfaceType
                )
                if !profiles.contains(where: { $0.matches(baseURL: candidate.baseURL, model: candidate.model, interfaceType: candidate.interfaceType) }) {
                    var migrated = candidate
                    migrated.legacyAPIKey = apiKey
                    profiles.append(migrated)
                }
            }
        }
        schemaVersion = 4
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(4, forKey: .schemaVersion)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(interfaceType, forKey: .interfaceType)
        try container.encode(reasoningMode, forKey: .reasoningMode)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(compressionEnabled, forKey: .compressionEnabled)
        try container.encode(compressionThresholdPercent, forKey: .compressionThresholdPercent)
        try container.encode(simulateContextFill, forKey: .simulateContextFill)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(routePolicy, forKey: .routePolicy)
        try container.encode(advancedFeatures, forKey: .advancedFeatures)
    }

    mutating func normalizeCurrentConnection() {
        baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var activeProfile: LLMConnectionProfile? {
        profiles.first {
            $0.matches(baseURL: baseURL, model: model, interfaceType: interfaceType)
        }
    }

    @discardableResult
    mutating func saveCurrentProfile(apiKeyHint: String? = nil) -> LLMConnectionProfile? {
        normalizeCurrentConnection()
        guard !baseURL.isEmpty, !model.isEmpty else { return nil }

        if let existingIndex = profiles.firstIndex(where: {
            $0.matches(baseURL: baseURL, model: model, interfaceType: interfaceType)
        }) {
            var existing = profiles.remove(at: existingIndex)
            if let apiKeyHint {
                existing.apiKeyHint = apiKeyHint
            }
            profiles.insert(existing, at: 0)
            return existing
        }

        let profile = LLMConnectionProfile(
            baseURL: baseURL,
            model: model,
            apiKeyHint: apiKeyHint ?? LLMConnectionProfile.maskedHint(for: apiKey),
            interfaceType: interfaceType
        )
        profiles.insert(profile, at: 0)
        return profile
    }

    mutating func applyProfile(_ profile: LLMConnectionProfile) {
        baseURL = profile.baseURL
        model = profile.model
        interfaceType = profile.interfaceType
    }

    mutating func removeProfile(_ profile: LLMConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
    }

    var enableThinking: Bool {
        get { reasoningMode != .off }
        set { reasoningMode = newValue ? .high : .off }
    }
}

struct LLMStatus: Codable {
    var ok: Bool
    var url: String
    var model: String
    var maxModelLen: Int?
    var availableModels: [String]
    var message: String

    enum CodingKeys: String, CodingKey {
        case ok
        case url
        case model
        case maxModelLen = "max_model_len"
        case availableModels = "available_models"
        case message
    }
}

struct LLMUsageMetrics: Codable, Hashable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
}

struct LLMChatResult {
    var text: String
    var reasoning: String = ""
    var usage: LLMUsageMetrics
    var endpoint: LLMEndpointDescriptor? = nil
    var requestId: String? = nil
    var latencyMs: Int? = nil
    var finishReason: String? = nil
}

struct LLMEndpointDescriptor: Hashable {
    var id: String
    var displayName: String
    var baseURL: String
    var model: String
    var interfaceType: LLMInterfaceKind
}

struct LLMRequest {
    var id: String
    var messages: [PromptMessage]
    var attachments: [AttachmentMetadata]
    var maxTokens: Int
    var reasoningMode: ReasoningMode
    var structuredOutput: StructuredOutputSchema?
}

enum LLMEvent {
    case started(requestId: String, endpoint: LLMEndpointDescriptor)
    case reasoningDelta(String)
    case textDelta(String)
    case usage(LLMUsageMetrics)
    case completed(finishReason: String?)
}

struct StructuredOutputSchema {
    var name: String
    var description: String
    var schema: [String: Any]
}

struct ConversationTitle: Codable {
    var title: String
}

struct SummaryV2: Codable {
    var summary: String
}

struct PromptMessage {
    var role: MessageRole
    var content: String
}

extension Date {
    static var timestamp: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

func parseTimestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }
    return ISO8601DateFormatter().date(from: value)
}
