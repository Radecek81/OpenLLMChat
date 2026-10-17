import CryptoKit
import Foundation
import UniformTypeIdentifiers

final class ConversationStore {
    private let fileManager = FileManager.default
    let supportRoot: URL
    private let conversationsDirectory: URL
    private let settingsFile: URL

    init() throws {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        supportRoot = appSupport.appendingPathComponent(AppDefaults.supportDirectoryName, isDirectory: true)
        conversationsDirectory = supportRoot.appendingPathComponent("conversations", isDirectory: true)
        settingsFile = supportRoot.appendingPathComponent("settings.json")

        try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportRoot.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: conversationsDirectory.path)
    }

    func loadSettings() -> AppSettings {
        guard
            let data = try? Data(contentsOf: settingsFile),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    func saveSettings(_ settings: AppSettings) throws {
        let data = try JSONEncoder.pretty.encode(settings)
        try data.write(to: settingsFile, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
    }

    func listConversations() throws -> [Conversation] {
        let urls = try fileManager.contentsOfDirectory(
            at: conversationsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let conversations = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Conversation? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let conversation = try? JSONDecoder().decode(Conversation.self, from: data),
                      isValidConversationID(conversation.id)
                else { return nil }
                return conversation
            }
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func createConversation() throws -> Conversation {
        let conversation = Conversation()
        try saveConversation(conversation)
        return conversation
    }

    func loadConversation(id: String) throws -> Conversation {
        let url = try conversationFileURL(id: id)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Conversation.self, from: data)
    }

    func saveConversation(_ conversation: Conversation) throws {
        var conversation = conversation
        if let lastMessage = conversation.messages.last {
            conversation.updatedAt = lastMessage.ts
        }
        let data = try JSONEncoder.pretty.encode(conversation)
        let directory = try conversationDirectory(id: conversation.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fileURL = try conversationFileURL(id: conversation.id)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func deleteConversation(id: String) throws {
        let fileURL = try conversationFileURL(id: id)
        let directoryURL = try conversationDirectory(id: id)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
    }

    func storeAttachments(_ attachments: [PendingAttachment], in conversationID: String) throws -> [AttachmentMetadata] {
        let filesDirectory = try conversationDirectory(id: conversationID).appendingPathComponent("files", isDirectory: true)
        try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: filesDirectory.path)

        return try attachments.map { attachment in
            let hash = sha256(attachment.data)
            let attachmentID = String(hash.prefix(12))
            let safeName = safeFilename(attachment.filename)
            let storedURL = filesDirectory.appendingPathComponent("\(attachmentID)_\(safeName)")
            try attachment.data.write(to: storedURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storedURL.path)
            return AttachmentMetadata(
                attachmentId: attachmentID,
                filename: safeName,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.sizeBytes,
                storedPath: storedURL.path.replacingOccurrences(of: supportRoot.path + "/", with: ""),
                sha256: hash
            )
        }
    }

    func loadAttachmentData(_ metadata: AttachmentMetadata) throws -> Data {
        guard !metadata.storedPath.hasPrefix("/") else { throw StoreError.invalidStoredPath }
        let url = supportRoot.appendingPathComponent(metadata.storedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowedPrefix = supportRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(allowedPrefix) else { throw StoreError.invalidStoredPath }
        return try Data(contentsOf: url)
    }

    func loadAttachmentText(_ metadata: AttachmentMetadata) throws -> String {
        let data = try loadAttachmentData(metadata)
        let text: String
        if let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        return truncate(text)
    }

    func makePendingAttachments(from urls: [URL]) throws -> [PendingAttachment] {
        try urls.map(makePendingAttachment)
    }

    func mimeType(for url: URL) -> String {
        if let typeIdentifier = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let mime = typeIdentifier.preferredMIMEType {
            return mime
        }
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private func makePendingAttachment(from url: URL) throws -> PendingAttachment {
        if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > AppDefaults.maxFileSizeBytes {
            throw StoreError.fileTooLarge
        }
        let data = try Data(contentsOf: url)
        if data.count > AppDefaults.maxFileSizeBytes {
            throw StoreError.fileTooLarge
        }

        let mimeType = mimeType(for: url)
        if !AttachmentRules.isAllowed(mimeType) {
            throw StoreError.unsupportedType
        }

        return PendingAttachment(
            url: url,
            filename: url.lastPathComponent,
            mimeType: mimeType,
            sizeBytes: data.count,
            data: data
        )
    }

    private func conversationFileURL(id: String) throws -> URL {
        guard isValidConversationID(id) else { throw StoreError.invalidConversationID }
        return conversationsDirectory.appendingPathComponent("\(id).json")
    }

    private func conversationDirectory(id: String) throws -> URL {
        guard isValidConversationID(id) else { throw StoreError.invalidConversationID }
        return conversationsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func isValidConversationID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func safeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }

    private func truncate(_ text: String) -> String {
        guard text.count > AppDefaults.maxTextInPromptPerFile else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: AppDefaults.maxTextInPromptPerFile)
        return String(text[..<cutoff]) + "\n...[zbytek oříznut kvůli limitu \(AppDefaults.maxTextInPromptPerFile) znaků]"
    }
}

enum StoreError: LocalizedError {
    case unsupportedType
    case fileTooLarge
    case invalidConversationID
    case invalidStoredPath

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            return L10n.choose(
                "Nepodporovaný typ souboru; pošli textový formát nebo povolený MIME.",
                "Unsupported file type; send a text format or an allowed MIME type."
            )
        case .fileTooLarge:
            return L10n.choose("Soubor je příliš velký.", "The file is too large.")
        case .invalidConversationID:
            return L10n.choose("Neplatné ID konverzace.", "Invalid conversation ID.")
        case .invalidStoredPath:
            return L10n.choose("Neplatná cesta k příloze.", "Invalid attachment path.")
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
