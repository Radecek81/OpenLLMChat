import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showingImporter = false
    @State private var showingKnowledgeImporter = false
    @State private var showingSavedProfiles = false
    @State private var promptEditorHeight: CGFloat = 72

    private let bottomAnchor = "chat-bottom"

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                HSplitView {
                    sidebar
                        .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)

                    VStack(spacing: 0) {
                        header
                        Divider()
                        messagesPane
                        Divider()
                        composer
                    }
                    .frame(minWidth: 860, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                .frame(minWidth: 1180, minHeight: 780)
                .background(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor),
                            Color.blue.opacity(0.03),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

                if viewModel.isAdvancedPanelVisible || viewModel.isDebugPanelVisible || viewModel.isCapabilitiesPanelVisible {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if viewModel.isDebugPanelVisible {
                                    viewModel.toggleDebugPanel()
                                }
                                if viewModel.isAdvancedPanelVisible {
                                    viewModel.toggleAdvancedPanel()
                                }
                                if viewModel.isCapabilitiesPanelVisible {
                                    viewModel.toggleCapabilitiesPanel()
                                }
                            }
                        }
                        .zIndex(5)
                }

                HStack(spacing: 0) {
                    if viewModel.isDebugPanelVisible {
                        DebugPanelView(
                            log: viewModel.debugLog,
                            onClose: { viewModel.toggleDebugPanel() },
                            onClear: { viewModel.clearDebugLog() }
                        )
                        .frame(width: debugPanelWidth(for: geometry.size.width))
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }

                    if viewModel.isAdvancedPanelVisible {
                        AdvancedPanelView(
                            settings: $viewModel.settings,
                            maxTokensText: maxTokensBinding,
                            maxContextTokensText: maxContextTokensBinding,
                            currentTotalTokens: viewModel.lastTotalTokens,
                            maxModelLen: viewModel.maxModelContextLength,
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    viewModel.toggleAdvancedPanel()
                                }
                            }
                        )
                        .frame(width: min(340, geometry.size.width * 0.34))
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }

                    if viewModel.isCapabilitiesPanelVisible {
                        CapabilitiesPanelView(
                            settings: $viewModel.settings.advancedFeatures,
                            embeddingAPIKey: $viewModel.embeddingAPIKey,
                            speechAPIKey: $viewModel.speechAPIKey,
                            mcpToken: $viewModel.mcpGatewayToken,
                            knowledgeBase: viewModel.knowledgeBase,
                            voiceService: viewModel.voiceService,
                            mcpGateway: viewModel.mcpGateway,
                            onChooseDocuments: { showingKnowledgeImporter = true },
                            onSave: { viewModel.saveAdvancedFeatures() },
                            onRefreshMCP: { viewModel.refreshMCPTools() },
                            onClose: { viewModel.toggleCapabilitiesPanel() }
                        )
                        .frame(width: min(460, geometry.size.width * 0.42))
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .zIndex(10)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .fileImporter(
            isPresented: $showingKnowledgeImporter,
            allowedContentTypes: [.plainText, .pdf, .json, .commaSeparatedText, .rtf, .item],
            allowsMultipleSelection: true,
            onCompletion: handleKnowledgeImport
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.choose("Konverzace", "Conversations"))
                        .font(.title3.weight(.semibold))
                    Text("\(viewModel.conversations.count) \(L10n.choose("chatů", "chats"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.choose("Nový chat", "New chat")) {
                    viewModel.createConversation()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.conversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            isSelected: conversation.id == viewModel.selectedConversationID,
                            onSelect: { viewModel.selectConversation(conversation.id) },
                            onDelete: { viewModel.deleteConversation(conversation.id) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                HStack(spacing: 14) {
                    Image("logo", bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppDefaults.appName)
                            .font(.title2.weight(.semibold))
                        Text(L10n.choose("Nativní macOS klient pro OpenAI-kompatibilní LLM", "Native macOS client for OpenAI-compatible LLM"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    TagView(text: viewModel.modelTagText, accent: .blue, isMuted: false)
                    TagView(
                        text: viewModel.isSending
                            ? L10n.choose("● Živý stream", "● Live stream")
                            : viewModel.activeEndpointText,
                        accent: viewModel.isSending ? .green : .purple,
                        isMuted: !viewModel.isSending
                    )
                    TagView(text: viewModel.summaryStateText, accent: .secondary, isMuted: true)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                HeaderField(title: L10n.choose("LLM konfigurace", "LLM configuration")) {
                    HStack(spacing: 8) {
                        Button {
                            showingSavedProfiles.toggle()
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(viewModel.activeProfileTitle)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(viewModel.activeProfileSubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingSavedProfiles, arrowEdge: .bottom) {
                            SavedProfilesPopover(
                                title: L10n.choose("Uložené konfigurace", "Saved configurations"),
                                profiles: viewModel.settings.profiles,
                                activeProfileID: viewModel.settings.activeProfile?.id,
                                onSelect: { profile in
                                    viewModel.applyProfile(profile)
                                    showingSavedProfiles = false
                                },
                                onDelete: { profile in
                                    viewModel.removeProfile(profile)
                                }
                            )
                        }

                        Button {
                            viewModel.saveCurrentProfile()
                            showingSavedProfiles = false
                        } label: {
                            Image(systemName: "plus")
                                .font(.headline.weight(.semibold))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        .help(L10n.choose("Uložit aktuální konfiguraci", "Save current configuration"))
                    }
                }

                HeaderField(title: L10n.choose("Uvažování", "Reasoning")) {
                    Picker("", selection: $viewModel.settings.reasoningMode) {
                        ForEach(ReasoningMode.allCases) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
                .fixedSize()
            }

            HStack(alignment: .bottom, spacing: 12) {
                HeaderField(title: "LLM URL") {
                    TextField("http://127.0.0.1:11434/v1", text: $viewModel.settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                }

                HeaderField(title: "LLM model") {
                    TextField("local-model", text: $viewModel.settings.model)
                        .textFieldStyle(.roundedBorder)
                }

                HeaderField(title: L10n.choose("API klíč", "API key")) {
                    SecureField("Bearer token", text: $viewModel.settings.apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                HeaderField(title: L10n.choose("Rozhraní", "Interface")) {
                    Picker("", selection: $viewModel.settings.interfaceType) {
                        ForEach(LLMInterfaceKind.allCases) { interfaceType in
                            Text(interfaceType.localizedTitle).tag(interfaceType)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 190, alignment: .leading)
                }

                Button(L10n.choose("Použít", "Apply")) {
                    Task {
                        await viewModel.applySettings()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button(viewModel.isDebugPanelVisible ? "DEBUG ON" : "DEBUG") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.toggleDebugPanel()
                    }
                }
                .buttonStyle(.bordered)

                Button(viewModel.isAdvancedPanelVisible ? L10n.choose("Pokročilé ON", "Advanced ON") : L10n.choose("Pokročilé", "Advanced")) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.toggleAdvancedPanel()
                    }
                }
                .buttonStyle(.bordered)

                Button(viewModel.isCapabilitiesPanelVisible ? "P2–P4 ON" : "P2–P4") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.toggleCapabilitiesPanel()
                    }
                }
                .buttonStyle(.borderedProminent)

            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
        )
    }

    private var messagesPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let conversation = viewModel.selectedConversation,
                       conversation.messages.isEmpty
                    {
                        emptyState
                    } else if let conversation = viewModel.selectedConversation {
                        ForEach(conversation.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    } else {
                        emptyState
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(22)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.selectedConversationID) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.selectedConversation?.messages.count ?? 0) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.streamedCharacterCount) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !viewModel.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.pendingAttachments) { attachment in
                            PendingAttachmentChip(
                                attachment: attachment,
                                onRemove: { viewModel.removePendingAttachment(attachment) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .help(L10n.choose("Přiložit soubor", "Attach file"))

                Button {
                    viewModel.toggleVoiceRecording()
                } label: {
                    Image(systemName: viewModel.voiceService.isRecording ? "mic.circle.fill" : "mic")
                        .font(.title3)
                        .foregroundStyle(viewModel.voiceService.isRecording ? .red : .primary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .help(L10n.choose("Nahrát a přepsat řeč", "Record and transcribe speech"))

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )

                    PromptTextEditor(
                        text: $viewModel.draftText,
                        dynamicHeight: $promptEditorHeight,
                        isEnabled: !viewModel.isSending,
                        onSubmit: {
                            viewModel.startSending()
                        }
                    )
                    .frame(height: promptEditorHeight)
                    .padding(.horizontal, 2)

                    if viewModel.draftText.isEmpty {
                        Text(L10n.choose("Zeptej se... (Enter = odeslat, Shift+Enter = nový řádek)", "Ask something... (Enter = send, Shift+Enter = newline)"))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .allowsHitTesting(false)
                    }
                }

                Button {
                    if viewModel.isSending {
                        viewModel.stopSending()
                    } else {
                        viewModel.startSending()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: viewModel.isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.title2)
                        Text(viewModel.isSending ? L10n.choose("Stop", "Stop") : L10n.choose("Odeslat", "Send"))
                            .font(.caption.weight(.medium))
                    }
                    .frame(width: 78, height: 72)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isSending ? .red : .accentColor)
                .disabled(!viewModel.isSending && !viewModel.canSend)
            }

            UsageProgressBars(
                responseProgress: viewModel.responseProgress,
                memoryProgress: viewModel.memoryProgress,
                completionTokens: viewModel.lastCompletionTokens,
                maxTokens: viewModel.settings.maxTokens,
                totalTokens: viewModel.lastTotalTokens,
                maxModelLen: viewModel.maxModelContextLength
            )

            HStack(spacing: 10) {
                StatusDot(kind: viewModel.statusKind)
                Text(viewModel.statusMessage.isEmpty ? viewModel.hintText : viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(viewModel.statusKind == .error ? .red : .secondary)
                    .lineLimit(2)
                Spacer()
                Text(viewModel.hintText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.choose("Napiš první zprávu", "Write the first message"))
                .font(.title3.weight(.semibold))
            Text(L10n.choose("Přidej soubor přes sponku nebo pošli text. Konverzace se ukládá lokálně a starší zprávy se průběžně shrnují.", "Attach a file or send text. Conversations are stored locally and older messages can be summarized in the background."))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.blue.opacity(0.05))
        )
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            var scopedURLs: [URL] = []
            for url in urls where url.startAccessingSecurityScopedResource() {
                scopedURLs.append(url)
            }
            viewModel.addAttachments(from: urls)
            for url in scopedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        case let .failure(error):
            viewModel.statusMessage = error.localizedDescription
            viewModel.statusKind = .error
        }
    }

    private func handleKnowledgeImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            viewModel.indexKnowledgeFiles(urls)
        case let .failure(error):
            viewModel.statusMessage = error.localizedDescription
            viewModel.statusKind = .error
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private func debugPanelWidth(for totalWidth: CGFloat) -> CGFloat {
        min(max(420, totalWidth * 0.42), totalWidth * 0.5)
    }

    private var maxTokensBinding: Binding<String> {
        Binding(
            get: { String(viewModel.settings.maxTokens) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                if let value = Int(digits), value > 0 {
                    viewModel.settings.maxTokens = value
                } else if digits.isEmpty {
                    viewModel.settings.maxTokens = AppDefaults.maxTokens
                }
            }
        )
    }

    private var maxContextTokensBinding: Binding<String> {
        Binding(
            get: { viewModel.activeProfileMaxContextText },
            set: { viewModel.setActiveProfileMaxContext($0.filter(\.isNumber)) }
        )
    }
}

private struct HeaderField<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 8) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TagView: View {
    let text: String
    let accent: Color
    let isMuted: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(accent.opacity(isMuted ? 0.08 : 0.12))
            .foregroundStyle(isMuted ? Color.secondary : accent)
            .clipShape(Capsule())
    }
}

private struct StatusDot: View {
    let kind: AppViewModel.StatusKind

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private var color: Color {
        switch kind {
        case .idle:
            return .secondary.opacity(0.5)
        case .sending:
            return .orange
        case .done:
            return .green
        case .error:
            return .red
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(conversation.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(conversation.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("\(conversation.messageCount) \(L10n.choose("zpráv", "messages")) · \(timestamp(conversation.updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isSelected ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
                        .help(L10n.choose("Smazat chat", "Delete chat"))
        }
    }

    private func timestamp(_ value: String) -> String {
        guard let date = parseTimestamp(value) else {
            return value
        }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    @State private var reasoningExpanded = false

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble
                Spacer(minLength: 60)
            } else {
                Spacer(minLength: 60)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(roleTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if message.status == "streaming" {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.choose("Odpověď přichází živě", "Response is streaming live"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            if !message.reasoning.isEmpty {
                DisclosureGroup(isExpanded: $reasoningExpanded) {
                    Text(message.reasoning)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                } label: {
                    Label(
                        reasoningExpanded
                            ? L10n.choose("Skrýt uvažování", "Hide reasoning")
                            : L10n.choose("Zobrazit uvažování", "Show reasoning"),
                        systemImage: "brain.head.profile"
                    )
                    .font(.caption.weight(.medium))
                }
            }

            if !message.content.isEmpty {
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let citations = message.parts.filter { $0.kind == .citation }
            if !citations.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label(L10n.choose("Použité zdroje", "Sources used"), systemImage: "books.vertical")
                        .font(.caption.weight(.semibold))
                    ForEach(citations) { citation in
                        Text("• \(citation.text) · \(citation.metadata?["range"] ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("score \(citation.metadata?["score"] ?? "n/a")")
                    }
                }
                .padding(10)
                .background(Color.purple.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !message.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        HStack(spacing: 8) {
                            Image(systemName: attachmentIcon(for: attachment.mimeType))
                                .foregroundStyle(.secondary)
                            Text("\(attachment.filename) · \(formatBytes(attachment.sizeBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Text(timestamp(message.ts))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if message.status == "error" {
                    Text(L10n.choose("chyba", "error"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                } else if message.status == "cancelled" {
                    Text(L10n.choose("zastaveno", "stopped"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if let usage = message.usage, let total = usage.totalTokens {
                    Text("· \(total) tok")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let latency = message.latencyMs {
                    Text("· \(latency) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 720, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var roleTitle: String {
        switch message.role {
        case .assistant:
            return L10n.choose("Asistent", "Assistant")
        case .system:
            return L10n.choose("Systém", "System")
        case .user:
            return L10n.choose("Ty", "You")
        }
    }

    private var background: AnyShapeStyle {
        switch message.role {
        case .assistant:
            return AnyShapeStyle(Color.primary.opacity(0.05))
        case .system:
            return AnyShapeStyle(Color.orange.opacity(0.10))
        case .user:
            return AnyShapeStyle(Color.blue.opacity(0.12))
        }
    }

    private func timestamp(_ value: String) -> String {
        guard let date = parseTimestamp(value) else {
            return value
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func attachmentIcon(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") {
            return "photo"
        }
        if mimeType.hasPrefix("video/") {
            return "film"
        }
        if mimeType.hasPrefix("audio/") {
            return "waveform"
        }
        if mimeType.contains("pdf") {
            return "doc.richtext"
        }
        return "doc"
    }
}

private struct PendingAttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(attachment.mimeType) · \(formatBytes(attachment.sizeBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var icon: String {
        if attachment.mimeType.hasPrefix("image/") {
            return "photo"
        }
        if attachment.mimeType.hasPrefix("video/") {
            return "film"
        }
        if attachment.mimeType.hasPrefix("audio/") {
            return "waveform"
        }
        return "doc"
    }
}

private struct SavedProfilesPopover: View {
    let title: String
    let profiles: [LLMConnectionProfile]
    let activeProfileID: String?
    let onSelect: (LLMConnectionProfile) -> Void
    let onDelete: (LLMConnectionProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            if profiles.isEmpty {
                Text(L10n.choose("Zatím žádné uložené položky.", "No saved items yet."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(profiles) { profile in
                            HStack(spacing: 10) {
                                Button(role: .destructive) {
                                    onDelete(profile)
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    onSelect(profile)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(profile.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                            if activeProfileID == profile.id {
                                                Text(L10n.choose("aktivní", "active"))
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.blue.opacity(0.14))
                                                    .foregroundStyle(.blue)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(profile.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 420, height: 260)
    }
}

private struct DebugPanelView: View {
    let log: String
    let onClose: () -> Void
    let onClear: () -> Void

    private let bottomID = "debug-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("DEBUG")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.green.opacity(0.95))
                Spacer()
                Button(L10n.choose("Vyčistit", "Clear"), action: onClear)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.green.opacity(0.9))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundStyle(Color.green.opacity(0.9))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(L10n.choose("Zavřít panel", "Close panel"))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(log.isEmpty ? L10n.choose("Zatím bez logu komunikace s LLM.", "No LLM communication log yet.") : log)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.green.opacity(0.95))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(16)
                }
                .background(Color.clear)
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: log) { _ in
                    scrollToBottom(proxy)
                }
            }
        }
        .padding(18)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.74))
                .background(.ultraThinMaterial)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.green.opacity(0.35))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 16, x: -8, y: 0)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

private struct AdvancedPanelView: View {
    @Binding var settings: AppSettings
    let maxTokensText: Binding<String>
    let maxContextTokensText: Binding<String>
    let currentTotalTokens: Int
    let maxModelLen: Int
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.choose("Pokročilé", "Advanced"))
                    .font(.headline.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(L10n.choose("Zavřít panel", "Close panel"))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("max_tokens")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("4096", text: maxTokensText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.choose("Kontextový limit profilu", "Profile context limit"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(L10n.choose("např. 32768", "e.g. 32768"), text: maxContextTokensText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(maxContextTokensText.wrappedValue.isEmpty && settings.activeProfile == nil)
                Text(L10n.choose("Prázdné = neznámé; probe může hodnotu doplnit.", "Empty = unknown; a probe may populate it."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle(L10n.choose("Komprese", "Compression"), isOn: $settings.compressionEnabled)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.choose("Práh komprese", "Compression threshold"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(settings.compressionThresholdPercent)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(settings.compressionThresholdPercent) },
                            set: { value in
                                let rounded = Int((value / 10).rounded() * 10)
                                settings.compressionThresholdPercent = min(90, max(10, rounded))
                            }
                        ),
                        in: 10 ... 90,
                        step: 10
                    )
                    .disabled(!settings.compressionEnabled)
                }
            }

            Toggle(L10n.choose("Simulace zaplnění", "Fill simulation"), isOn: $settings.simulateContextFill)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    L10n.choose("Automatický fallback", "Automatic fallback"),
                    isOn: $settings.routePolicy.automaticFallbackEnabled
                )
                .toggleStyle(.switch)
                Text(
                    L10n.choose(
                        "Při timeoutu, 429 nebo 5xx zkusí další uložené profily v pořadí. Chyby konfigurace a autentizace se neopakují.",
                        "On timeout, 429, or 5xx, tries other saved profiles in order. Configuration and authentication errors are not retried."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.choose("Aktuální stav kontextu", "Current context state"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(currentTotalTokens) / \(maxModelLen)")
                    .font(.system(.body, design: .monospaced))
            }

            Spacer()
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.blue.opacity(0.25))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, x: -6, y: 0)
    }
}

private struct CapabilitiesPanelView: View {
    @Binding var settings: AdvancedFeatureSettings
    @Binding var embeddingAPIKey: String
    @Binding var speechAPIKey: String
    @Binding var mcpToken: String
    @ObservedObject var knowledgeBase: KnowledgeBase
    @ObservedObject var voiceService: VoiceService
    @ObservedObject var mcpGateway: MCPGateway
    let onChooseDocuments: () -> Void
    let onSave: () -> Void
    let onRefreshMCP: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("P2–P4")
                        .font(.headline.weight(.semibold))
                    Text(L10n.choose("Znalosti · hlas · nástroje · experimenty", "Knowledge · voice · tools · experiments"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox(L10n.choose("RAG a hybridní vyhledávání", "RAG and hybrid retrieval")) {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle(L10n.choose("Přidávat znalosti do kontextu", "Add knowledge to context"), isOn: $settings.rag.enabled)
                            TextField(L10n.choose("Embedding URL", "Embedding URL"), text: $settings.rag.embeddingBaseURL)
                                .textFieldStyle(.roundedBorder)
                            TextField(L10n.choose("Embedding model", "Embedding model"), text: $settings.rag.embeddingModel)
                                .textFieldStyle(.roundedBorder)
                            SecureField(L10n.choose("API klíč embeddingů", "Embedding API key"), text: $embeddingAPIKey)
                                .textFieldStyle(.roundedBorder)
                            Stepper("top-k: \(settings.rag.topK)", value: $settings.rag.topK, in: 1 ... 12)
                            HStack {
                                Text(L10n.choose("Váha dense", "Dense weight"))
                                Slider(value: $settings.rag.denseWeight, in: 0 ... 1, step: 0.05)
                                Text(settings.rag.denseWeight.formatted(.number.precision(.fractionLength(2))))
                                    .monospacedDigit()
                            }
                            HStack {
                                Button(knowledgeBase.isIndexing ? L10n.choose("Indexuji…", "Indexing…") : L10n.choose("Přidat dokumenty", "Add documents"), action: onChooseDocuments)
                                    .disabled(knowledgeBase.isIndexing)
                                Button(L10n.choose("Vymazat index", "Clear index"), role: .destructive) { knowledgeBase.removeAll() }
                            }
                            Text("\(knowledgeBase.documents.count) \(L10n.choose("dokumentů", "documents")) · \(knowledgeBase.status)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(knowledgeBase.documents) { document in
                                HStack {
                                    Image(systemName: "doc.text.magnifyingglass")
                                    VStack(alignment: .leading) {
                                        Text(document.title).lineLimit(1)
                                        Text("\(document.chunkCount) chunks").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { knowledgeBase.removeDocument(id: document.id) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }

                    GroupBox(L10n.choose("Hlas", "Voice")) {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle(L10n.choose("Povolit push-to-talk", "Enable push-to-talk"), isOn: $settings.voice.enabled)
                            TextField("STT URL", text: $settings.voice.transcriptionURL).textFieldStyle(.roundedBorder)
                            TextField("STT model", text: $settings.voice.transcriptionModel).textFieldStyle(.roundedBorder)
                            TextField("TTS URL", text: $settings.voice.speechURL).textFieldStyle(.roundedBorder)
                            TextField(L10n.choose("Záložní TTS URL", "Fallback TTS URL"), text: $settings.voice.fallbackSpeechURL).textFieldStyle(.roundedBorder)
                            HStack {
                                TextField(L10n.choose("Hlas", "Voice"), text: $settings.voice.voice)
                                TextField(L10n.choose("Formát", "Format"), text: $settings.voice.responseFormat)
                            }
                            .textFieldStyle(.roundedBorder)
                            SecureField(L10n.choose("API klíč hlasu", "Voice API key"), text: $speechAPIKey).textFieldStyle(.roundedBorder)
                            Toggle(L10n.choose("Automaticky přečíst odpověď", "Automatically speak responses"), isOn: $settings.voice.autoSpeak)
                            if voiceService.isPlaying {
                                Button(L10n.choose("Zastavit přehrávání", "Stop playback")) { voiceService.stopPlayback() }
                            }
                        }
                        .padding(.top, 6)
                    }

                    GroupBox(L10n.choose("Nástroje a MCP gateway", "Tools and MCP gateway")) {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle(L10n.choose("Povolit nástroje", "Enable tools"), isOn: $settings.tools.enabled)
                            TextField("MCP HTTP URL", text: $settings.tools.mcpGatewayURL).textFieldStyle(.roundedBorder)
                            SecureField("MCP bearer token", text: $mcpToken).textFieldStyle(.roundedBorder)
                            Toggle(L10n.choose("Vzdálené nástroje vždy schvalovat", "Always approve remote tools"), isOn: $settings.tools.requireApprovalForRemoteTools)
                            Stepper(L10n.choose("Maximum kroků: \(settings.tools.maxSteps)", "Maximum steps: \(settings.tools.maxSteps)"), value: $settings.tools.maxSteps, in: 1 ... 10)
                            Button(L10n.choose("Načíst nástroje", "Load tools"), action: onRefreshMCP)
                            ForEach(mcpGateway.tools) { tool in
                                Label(tool.name, systemImage: "wrench.and.screwdriver")
                                    .font(.caption)
                                    .help(tool.description)
                            }
                        }
                        .padding(.top, 6)
                    }

                    GroupBox(L10n.choose("Experimentální P4", "Experimental P4")) {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle(L10n.choose("Dlouhodobá paměť", "Long-term memory"), isOn: $settings.experimental.longTermMemoryEnabled)
                            Toggle(L10n.choose("Běhy na pozadí", "Background runs"), isOn: $settings.experimental.backgroundRunsEnabled)
                            Toggle("OpenAI Responses adapter", isOn: $settings.experimental.responsesAdapterEnabled)
                            Toggle(L10n.choose("Full-duplex hlas", "Full-duplex voice"), isOn: $settings.experimental.fullDuplexVoiceEnabled)
                            Toggle(L10n.choose("Computer use (vyžaduje sandbox a schvalování)", "Computer use (requires sandbox and approvals)"), isOn: $settings.experimental.computerUseEnabled)
                            Text(L10n.choose("Experimentální přepínače jsou ve výchozím stavu vypnuté. Computer use nesmí provést akci bez samostatného sandboxu a potvrzení.", "Experimental switches are off by default. Computer use cannot perform an action without a separate sandbox and approval."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.vertical, 4)
            }

            Button(L10n.choose("Uložit nastavení P2–P4", "Save P2–P4 settings"), action: onSave)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) { Rectangle().fill(Color.purple.opacity(0.32)).frame(width: 1) }
        .shadow(color: .black.opacity(0.18), radius: 14, x: -6, y: 0)
    }
}

private struct UsageProgressBars: View {
    let responseProgress: Double
    let memoryProgress: Double
    let completionTokens: Int
    let maxTokens: Int
    let totalTokens: Int
    let maxModelLen: Int

    var body: some View {
        VStack(spacing: 8) {
            progressRow(
                title: L10n.choose("Limit odpovědi", "Response limit"),
                progress: responseProgress,
                color: Color.blue,
                detail: "\(completionTokens) / \(maxTokens)"
            )
            progressRow(
                title: L10n.choose("Stav paměti LLM", "LLM memory"),
                progress: memoryProgress,
                color: memoryColor,
                detail: "\(totalTokens) / \(maxModelLen)"
            )
        }
    }

    private func progressRow(title: String, progress: Double, color: Color, detail: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geometry.size.width * progress))
                }
            }
            .frame(height: 6)
        }
    }

    private var memoryColor: Color {
        let percent = memoryProgress * 100
        if percent >= 90 {
            return .red
        }
        if percent >= 80 {
            return .orange
        }
        return .green
    }
}
