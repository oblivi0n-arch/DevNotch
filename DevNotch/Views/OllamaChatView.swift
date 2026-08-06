import SwiftUI

struct OllamaChatView: View {
    @ObservedObject var gitService: GitStatusService

    @State private var messages: [ChatMessage] = []
    @State private var draft: String = ""
    @State private var stagedDiff: String = ""
    @State private var isStreaming = false
    @State private var noDiff = false
    @State private var lastError: OllamaError?
    @State private var committedMessageIds: Set<UUID> = []

    @FocusState private var isInputFocused: Bool

    private let client = OllamaClient()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(client.model)
                    .font(.system(size: 13, weight: .medium))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
            if noDiff {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("No staged changes")
                        .font(.system(size: 13, weight: .medium))
                    Text("Run git add first, or stage everything below")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Button(action: stageAll) {
                        Label("Stage All", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(messages) { message in
                                Group {
                                    if message.role == "system" {
                                        systemFeedbackView(message)
                                    } else if message.role == "assistant" && message.content.isEmpty && isStreaming {
                                        HStack(spacing: 6) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Generating response...")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(10)
                                    } else {
                                        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 2) {
                                            Text(message.content)
                                                .padding(10)
                                                .background(message.role == "user" ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                                                .cornerRadius(10)

                                            if message.role == "assistant" && isStreaming && message.id == messages.last?.id {
                                                Text(counterLabel(for: message.content))
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary)
                                                    .padding(.horizontal, 4)
                                            }
                                        }
                                    }
                                }
                                .background(message.role == "user" || (message.role == "assistant" && message.content.isEmpty && isStreaming) ? Color.clear : Color.clear)
                                .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: messages.count) {
                        scrollToBottom(proxy)
                    }
                    .onChange(of: messages.last?.content) {
                        scrollToBottom(proxy)
                    }
                }
            }

            if let error = lastError {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error.errorDescription ?? "Something went wrong")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Retry", action: retry)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    if let suggestion = error.recoverySuggestion {
                        Text(suggestion)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            if let lastAssistant = messages.last(where: { $0.role == "assistant" }), !isStreaming, !lastAssistant.content.isEmpty {
                let alreadyCommitted = committedMessageIds.contains(lastAssistant.id)
                HStack {
                    Button(action: { performCommit(for: lastAssistant) }) {
                        Label(
                            alreadyCommitted ? "Committed" : "Commit",
                            systemImage: alreadyCommitted ? "checkmark.circle.fill" : "checkmark.circle"
                        )
                    }
                    .disabled(alreadyCommitted)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Divider()
                .padding(.top, 8)

            HStack(spacing: 8) {
                TextField("Describe your change...", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .disabled(stagedDiff.isEmpty || isStreaming)
                    .onSubmit(send)
                    .focused($isInputFocused)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .disabled(draft.isEmpty || isStreaming || stagedDiff.isEmpty)
            }
            .padding(8)
            .background(.ultraThinMaterial)
        }
        .frame(width: 320, height: 400)
        .onAppear(perform: loadDiff)
    }

    private func loadDiff() {
        stagedDiff = gitService.stagedDiff()
        noDiff = stagedDiff.isEmpty
        if !noDiff {
            isInputFocused = true
        }
    }

    private func stageAll() {
        gitService.stageAll()
        loadDiff()
    }

    private func send() {
        let userText = draft
        draft = ""
        withAnimation(.easeOut(duration: 0.2)) {
            messages.append(ChatMessage(role: "user", content: userText))
        }
        generateResponse()
    }

    private func generateResponse() {
        lastError = nil
        withAnimation(.easeOut(duration: 0.2)) {
            messages.append(ChatMessage(role: "assistant", content: ""))
        }
        isStreaming = true

        let systemPrompt = """
        You write git commit messages in Conventional Commits format.

        Output exactly this shape:
        <type>(<scope>): <short imperative summary, max 72 chars>

        <body: 1-3 sentences explaining what changed and why, based on the diff>

        Output only the commit message, nothing else.

        Diff:
        \(stagedDiff)
        """

        var history: [OllamaMessage] = [OllamaMessage(role: "system", content: systemPrompt)]
        history += messages.dropLast()
            .filter { $0.role != "system" }
            .map { OllamaMessage(role: $0.role, content: $0.content) }

        Task {
            do {
                for try await chunk in client.streamChat(messages: history) {
                    await MainActor.run {
                        if let lastIndex = messages.indices.last {
                            messages[lastIndex].content += chunk
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    messages.removeLast()
                    lastError = (error as? OllamaError) ?? .connectionFailed
                }
            }
            await MainActor.run { isStreaming = false }
        }
    }

    private func retry() {
        guard messages.last?.role == "user" else { return }
        generateResponse()
    }

    private func performCommit(for message: ChatMessage) {
        do {
            try gitService.commit(message: message.content)
            committedMessageIds.insert(message.id)
            withAnimation(.easeOut(duration: 0.2)) {
                messages.append(ChatMessage(role: "system", content: "✅ Committed successfully"))
            }
        } catch {
            let reason = (error as? GitCommitError)?.errorDescription ?? error.localizedDescription
            withAnimation(.easeOut(duration: 0.2)) {
                messages.append(ChatMessage(role: "system", content: "❌ Commit failed: \(reason)"))
            }
        }
    }

    @ViewBuilder
    private func systemFeedbackView(_ message: ChatMessage) -> some View {
        let isError = message.content.hasPrefix("❌")
        HStack(spacing: 6) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? .red : .green)
            Text(message.content)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background((isError ? Color.red : Color.green).opacity(0.12))
        .cornerRadius(8)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let lastId = messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(lastId, anchor: .bottom)
        }
    }

    private func counterLabel(for text: String) -> String {
        let chars = text.count
        // Rough heuristic: ~4 characters per token for English text.
        let approxTokens = max(1, chars / 4)
        return "\(chars) chars · ~\(approxTokens) tokens"
    }
}
