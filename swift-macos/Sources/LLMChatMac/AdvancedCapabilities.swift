import AVFoundation
import CryptoKit
import Foundation
import PDFKit

struct RAGSettings: Codable, Hashable {
    var enabled = false
    var embeddingBaseURL = ""
    var embeddingModel = ""
    var expectedDimension = 1024
    var topK = 5
    var denseWeight = 0.72
}

struct VoiceSettings: Codable, Hashable {
    var enabled = false
    var transcriptionURL = ""
    var transcriptionModel = "whisper-1"
    var speechURL = ""
    var fallbackSpeechURL = ""
    var voice = "default"
    var responseFormat = "wav"
    var autoSpeak = false
    var vadEnabled = false
}

struct ToolSettings: Codable, Hashable {
    var enabled = false
    var maxSteps = 4
    var resultByteLimit = 65_536
    var mcpGatewayURL = ""
    var allowedTools: [String] = ["search_knowledge", "endpoint_status"]
    var requireApprovalForRemoteTools = true
}

struct ExperimentalSettings: Codable, Hashable {
    var longTermMemoryEnabled = false
    var backgroundRunsEnabled = false
    var responsesAdapterEnabled = false
    var fullDuplexVoiceEnabled = false
    var computerUseEnabled = false
}

struct AdvancedFeatureSettings: Codable, Hashable {
    var rag = RAGSettings()
    var voice = VoiceSettings()
    var tools = ToolSettings()
    var experimental = ExperimentalSettings()

    static let `default` = AdvancedFeatureSettings()
}

struct RetrievalCitation: Codable, Hashable, Identifiable {
    var id: String { chunkID }
    var documentID: String
    var chunkID: String
    var title: String
    var rangeStart: Int
    var rangeEnd: Int
    var score: Double
    var text: String
}

struct KnowledgeDocument: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var sourcePath: String
    var sha256: String
    var indexedAt: String
    var chunkCount: Int
}

struct KnowledgeChunk: Codable, Hashable, Identifiable {
    var id: String
    var documentID: String
    var title: String
    var text: String
    var rangeStart: Int
    var rangeEnd: Int
    var embedding: [Float]
    var terms: [String: Int]
}

struct KnowledgeIndex: Codable {
    var schemaVersion = 1
    var embeddingModel = ""
    var dimension = 0
    var documents: [KnowledgeDocument] = []
    var chunks: [KnowledgeChunk] = []
}

@MainActor
final class KnowledgeBase: ObservableObject {
    @Published private(set) var documents: [KnowledgeDocument] = []
    @Published private(set) var isIndexing = false
    @Published var status = ""

    private let indexURL: URL
    private var index = KnowledgeIndex()
    private let session: URLSession

    init(root: URL) {
        indexURL = root.appendingPathComponent("knowledge-index.json")
        session = URLSession(configuration: .ephemeral)
        load()
    }

    func ingest(urls: [URL], settings: RAGSettings, apiKey: String) async throws {
        guard !settings.embeddingBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AdvancedFeatureError.missingEmbeddingConfiguration }
        isIndexing = true
        defer { isIndexing = false }

        for url in urls {
            let text = try extractText(from: url)
            let data = Data(text.utf8)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let documentID = String(hash.prefix(24))
            removeDocument(id: documentID, persist: false)
            let segments = chunk(text)
            let vectors = try await embeddings(
                inputs: segments.map(\.text),
                settings: settings,
                apiKey: apiKey
            )
            guard vectors.count == segments.count else { throw AdvancedFeatureError.invalidEmbeddingResponse }
            let chunks = zip(segments, vectors).map { segment, vector in
                KnowledgeChunk(
                    id: String(SHA256.hash(data: Data("\(documentID):\(segment.start):\(segment.text)".utf8)).description.prefix(32)),
                    documentID: documentID,
                    title: url.lastPathComponent,
                    text: segment.text,
                    rangeStart: segment.start,
                    rangeEnd: segment.end,
                    embedding: vector,
                    terms: termFrequency(segment.text)
                )
            }
            let document = KnowledgeDocument(
                id: documentID,
                title: url.lastPathComponent,
                sourcePath: url.path,
                sha256: hash,
                indexedAt: Date.timestamp,
                chunkCount: chunks.count
            )
            index.documents.append(document)
            index.chunks.append(contentsOf: chunks)
            index.embeddingModel = settings.embeddingModel
            index.dimension = vectors.first?.count ?? 0
            if settings.expectedDimension > 0, index.dimension != settings.expectedDimension {
                removeDocument(id: documentID, persist: false)
                throw AdvancedFeatureError.embeddingDimension(expected: settings.expectedDimension, actual: index.dimension)
            }
            try persist()
            status = L10n.choose("Indexováno: \(url.lastPathComponent)", "Indexed: \(url.lastPathComponent)")
        }
        documents = index.documents.sorted { $0.indexedAt > $1.indexedAt }
    }

    func retrieve(query: String, settings: RAGSettings, apiKey: String) async throws -> [RetrievalCitation] {
        guard settings.enabled, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !index.chunks.isEmpty else { return [] }
        let queryVector = try await embeddings(inputs: [query], settings: settings, apiKey: apiKey).first ?? []
        let queryTerms = Set(tokenize(query))
        return index.chunks.map { chunk -> RetrievalCitation in
            let dense = cosine(queryVector, chunk.embedding)
            let lexicalHits = queryTerms.reduce(0) { $0 + (chunk.terms[$1] ?? 0) }
            let lexical = queryTerms.isEmpty ? 0 : min(1, Double(lexicalHits) / Double(queryTerms.count * 2))
            let score = settings.denseWeight * dense + (1 - settings.denseWeight) * lexical
            return RetrievalCitation(
                documentID: chunk.documentID,
                chunkID: chunk.id,
                title: chunk.title,
                rangeStart: chunk.rangeStart,
                rangeEnd: chunk.rangeEnd,
                score: score,
                text: chunk.text
            )
        }
        .sorted { $0.score > $1.score }
        .prefix(max(1, settings.topK))
        .map { $0 }
    }

    func removeDocument(id: String) {
        removeDocument(id: id, persist: true)
    }

    func removeAll() {
        index = KnowledgeIndex()
        documents = []
        try? FileManager.default.removeItem(at: indexURL)
        status = L10n.choose("Index byl vymazán", "Index cleared")
    }

    private func removeDocument(id: String, persist: Bool) {
        index.documents.removeAll { $0.id == id }
        index.chunks.removeAll { $0.documentID == id }
        documents = index.documents
        if persist { try? self.persist() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode(KnowledgeIndex.self, from: data) else { return }
        index = decoded
        documents = decoded.documents.sorted { $0.indexedAt > $1.indexedAt }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: Data.WritingOptions.atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private func extractText(from url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
            let value = (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
            guard !value.isEmpty else { throw AdvancedFeatureError.emptyDocument }
            return value
        }
        if ["doc", "docx", "rtf", "odt"].contains(url.pathExtension.lowercased()) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "txt", "-stdout", url.path]
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus == 0, let value = String(data: data, encoding: .utf8), !value.isEmpty { return value }
        }
        let data = try Data(contentsOf: url)
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw AdvancedFeatureError.unsupportedDocument }
        return value
    }

    private func chunk(_ text: String) -> [(text: String, start: Int, end: Int)] {
        let target = 1_600
        let overlap = 240
        var result: [(String, Int, Int)] = []
        var start = 0
        while start < text.count {
            let end = min(text.count, start + target)
            let lower = text.index(text.startIndex, offsetBy: start)
            let upper = text.index(text.startIndex, offsetBy: end)
            let value = String(text[lower ..< upper]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append((value, start, end)) }
            if end == text.count { break }
            start = max(start + 1, end - overlap)
        }
        return result
    }

    private func embeddings(inputs: [String], settings: RAGSettings, apiKey: String) async throws -> [[Float]] {
        let url = try endpointURL(settings.embeddingBaseURL, path: "embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppDefaults.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": settings.embeddingModel, "input": inputs])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { throw AdvancedFeatureError.embeddingRequestFailed }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { throw AdvancedFeatureError.invalidEmbeddingResponse }
        return items.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.compactMap { item in
            (item["embedding"] as? [NSNumber])?.map(\.floatValue)
        }
    }

    private func endpointURL(_ base: String, path: String) throws -> URL {
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else {
            throw AdvancedFeatureError.invalidEndpoint
        }
        var segments = components.path.split(separator: "/").map(String.init)
        if segments.last == path { return components.url! }
        if segments.last != "v1" { segments.append("v1") }
        segments.append(path)
        components.path = "/" + segments.joined(separator: "/")
        guard let url = components.url else { throw AdvancedFeatureError.invalidEndpoint }
        return url
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
    }

    private func termFrequency(_ text: String) -> [String: Int] {
        Dictionary(tokenize(text).map { ($0, 1) }, uniquingKeysWith: +)
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Double = 0, left: Double = 0, right: Double = 0
        for index in lhs.indices {
            let a = Double(lhs[index]), b = Double(rhs[index])
            dot += a * b; left += a * a; right += b * b
        }
        guard left > 0, right > 0 else { return 0 }
        return dot / (sqrt(left) * sqrt(right))
    }
}

@MainActor
final class VoiceService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    private let root: URL
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private let session = URLSession(configuration: .ephemeral)

    init(root: URL) {
        self.root = root
    }

    func startRecording() throws {
        let url = root.appendingPathComponent("voice-input.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.record()
        isRecording = true
    }

    func stopAndTranscribe(settings: VoiceSettings, apiKey: String) async throws -> String {
        guard let recorder else { return "" }
        recorder.stop()
        isRecording = false
        defer { try? FileManager.default.removeItem(at: recorder.url) }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: try validatedURL(settings.transcriptionURL))
        request.httpMethod = "POST"
        request.timeoutInterval = AppDefaults.requestTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let audio = try Data(contentsOf: recorder.url)
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(settings.transcriptionModel)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = json["text"] as? String else {
            throw AdvancedFeatureError.transcriptionFailed
        }
        return text
    }

    func speak(_ text: String, settings: VoiceSettings, apiKey: String) async throws {
        do { try await speak(text, urlString: settings.speechURL, settings: settings, apiKey: apiKey) }
        catch {
            guard !settings.fallbackSpeechURL.isEmpty else { throw error }
            try await speak(text, urlString: settings.fallbackSpeechURL, settings: settings, apiKey: apiKey)
        }
    }

    func stopPlayback() {
        player?.stop(); player = nil; isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.isPlaying = false }
    }

    private func speak(_ text: String, urlString: String, settings: VoiceSettings, apiKey: String) async throws {
        var request = URLRequest(url: try validatedURL(urlString))
        request.httpMethod = "POST"
        request.timeoutInterval = AppDefaults.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": text, "voice": settings.voice, "response_format": settings.responseFormat])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { throw AdvancedFeatureError.speechFailed }
        player = try AVAudioPlayer(data: data)
        player?.delegate = self
        player?.play()
        isPlaying = true
    }

    private func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw AdvancedFeatureError.invalidEndpoint }
        return url
    }
}

struct ToolDefinition: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var description: String
    var inputSchema: [String: String]
    var readOnly: Bool
    var source: String
}

struct ToolCall: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var argumentsJSON: String
    var source: String
}

struct ToolResult: Codable, Hashable {
    var callID: String
    var content: String
    var isError: Bool
}

@MainActor
final class MCPGateway: ObservableObject {
    @Published private(set) var tools: [ToolDefinition] = []
    private let session = URLSession(configuration: .ephemeral)

    func refresh(urlString: String, token: String) async throws {
        let result = try await request(method: "tools/list", params: [:], urlString: urlString, token: token)
        let list = ((result["tools"] as? [[String: Any]]) ?? []).compactMap { item -> ToolDefinition? in
            guard let name = item["name"] as? String else { return nil }
            return ToolDefinition(name: name, description: item["description"] as? String ?? "", inputSchema: [:], readOnly: false, source: urlString)
        }
        tools = list
    }

    func call(_ call: ToolCall, urlString: String, token: String, byteLimit: Int) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let result = try await request(method: "tools/call", params: ["name": call.name, "arguments": args], urlString: urlString, token: token)
        let data = try JSONSerialization.data(withJSONObject: result)
        guard data.count <= byteLimit else { throw AdvancedFeatureError.toolResultTooLarge }
        return ToolResult(callID: call.id, content: String(data: data, encoding: .utf8) ?? "{}", isError: false)
    }

    private func request(method: String, params: [String: Any], urlString: String, token: String) async throws -> [String: Any] {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw AdvancedFeatureError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AdvancedFeatureError.mcpRequestFailed }
        if let error = json["error"] as? [String: Any] { throw AdvancedFeatureError.mcpError(error["message"] as? String ?? "Unknown MCP error") }
        return json["result"] as? [String: Any] ?? [:]
    }
}

enum AdvancedFeatureError: LocalizedError {
    case invalidEndpoint, missingEmbeddingConfiguration, embeddingRequestFailed, invalidEmbeddingResponse
    case embeddingDimension(expected: Int, actual: Int)
    case unsupportedDocument, emptyDocument, transcriptionFailed, speechFailed, toolResultTooLarge, mcpRequestFailed, mcpError(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return L10n.choose("Neplatná URL služby.", "Invalid service URL.")
        case .missingEmbeddingConfiguration: return L10n.choose("Doplň URL a model embeddingů.", "Enter the embedding URL and model.")
        case .embeddingRequestFailed: return L10n.choose("Embedding endpoint požadavek odmítl.", "The embedding endpoint rejected the request.")
        case .invalidEmbeddingResponse: return L10n.choose("Neplatná odpověď embedding endpointu.", "Invalid embedding endpoint response.")
        case let .embeddingDimension(expected, actual): return L10n.choose("Embedding má rozměr \(actual), očekáváno \(expected).", "Embedding dimension is \(actual), expected \(expected).")
        case .unsupportedDocument: return L10n.choose("Dokument nelze převést na text.", "The document cannot be converted to text.")
        case .emptyDocument: return L10n.choose("Dokument neobsahuje čitelný text.", "The document contains no readable text.")
        case .transcriptionFailed: return L10n.choose("Přepis řeči selhal.", "Speech transcription failed.")
        case .speechFailed: return L10n.choose("Syntéza řeči selhala.", "Speech synthesis failed.")
        case .toolResultTooLarge: return L10n.choose("Výsledek nástroje překročil limit.", "The tool result exceeded the limit.")
        case .mcpRequestFailed: return L10n.choose("MCP gateway neodpověděla platně.", "The MCP gateway did not return a valid response.")
        case let .mcpError(message): return "MCP: \(message)"
        }
    }
}
