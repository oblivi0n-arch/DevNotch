import SwiftUI

private enum ChatMode: String, CaseIterable, Identifiable {
    case commit = "Commit"
    case tag = "Tag"

    var id: String { rawValue }
}

struct OllamaChatView: View {
    @ObservedObject var gitService: GitStatusService

    @State private var mode: ChatMode = .commit

    @State private var commitMessages: [ChatMessage] = []
    @State private var tagMessages: [ChatMessage] = []

    @State private var draft: String = ""

    @State private var stagedDiff: String = ""
    @State private var tagLastTag: String?
    @State private var tagCommitLog: String = ""

    @State private var isStreaming = false
    @State private var lastError: OllamaError?
    @State private var actionedMessageIds: Set<UUID> = []
    @State private var editingMessageId: UUID?
    @State private var editDraft: String = ""

    @FocusState private var isInputFocused: Bool

    private let client = OllamaClient()

    private var messages: [ChatMessage] {
        get { mode == .commit ? commitMessages : tagMessages }
        nonmutating set {
            if mode == .commit {
                commitMessages = newValue
            } else {
                tagMessages = newValue
            }
        }
    }

    private var contextIsEmpty: Bool {
        switch mode {
        case .commit: return stagedDiff.isEmpty
        case .tag: return tagCommitLog.isEmpty
        }
    }

    private var inputPlaceholder: String {
        switch mode {
        case .commit: return "Describe your change..."
        case .tag: return "Add context for the release notes (optional)..."
        }
    }

    private var lastUserMessage: ChatMessage? {
        messages.last(where: { $0.role == "user" })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(client.model)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Picker("Mode", selection: $mode) {
                    ForEach(ChatMode.allCases) { chatMode in
                        Text(chatMode.rawValue).tag(chatMode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if contextIsEmpty {
                VStack(spacing: 8) {
                    Image(systemName: mode == .commit ? "tray" : "tag")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text(mode == .commit ? "No staged changes" : "No commits since last tag")
                        .font(.system(size: 13, weight: .medium))
                    Text(mode == .commit ? "Run git add first, or stage everything below" : "Commit some changes first")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if mode == .commit {
                        Button(action: stageAll) {
                            Label("Stage All", systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .padding(.top, 4)
                    }
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
                                    } else if message.role == "user" && editingMessageId == message.id {
                                        editingBubble(message)
                                    } else {
                                        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 2) {
                                            Text(message.content)
                                                .padding(10)
                                                .background(message.role == "user" ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                                                .cornerRadius(10)
                                                .overlay(alignment: .topTrailing) {
                                                    if message.role == "user" && message.id == lastUserMessage?.id && !isStreaming && editingMessageId == nil {
                                                        Button(action: { beginEdit(message) }) {
                                                            Image(systemName: "pencil.circle.fill")
                                                                .font(.system(size: 14))
                                                                .foregroundColor(.secondary)
                                                                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                                                        }
                                                        .buttonStyle(.plain)
                                                        .offset(x: 10, y: -10)
                                                    }
                                                }

                                            if message.role == "assistant" && isStreaming && message.id == messages.last?.id {
                                                Text(counterLabel(for: message.content))
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary)
                                                    .padding(.horizontal, 4)
                                            }
                                        }
                                    }
                                }
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
                        Button("Retry", action: regenerate)
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
                let alreadyActioned = actionedMessageIds.contains(lastAssistant.id)
                HStack(spacing: 12) {
                    Button(action: regenerate) {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                    Button(action: { performAction(for: lastAssistant) }) {
                        Label(
                            actionLabel(actioned: alreadyActioned),
                            systemImage: alreadyActioned ? "checkmark.circle.fill" : "checkmark.circle"
                        )
                    }
                    .disabled(alreadyActioned)

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Divider()
                .padding(.top, 8)

            HStack(spacing: 8) {
                TextField(inputPlaceholder, text: $draft)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .disabled(contextIsEmpty || isStreaming)
                    .onSubmit(send)
                    .focused($isInputFocused)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .disabled(draft.isEmpty || isStreaming || contextIsEmpty)
            }
            .padding(8)
            .background(.ultraThinMaterial)
        }
        .frame(width: 320, height: 420)
        .onAppear(perform: loadContext)
        .onChange(of: mode) {
            loadContext()
        }
    }

    private func actionLabel(actioned: Bool) -> String {
        switch (mode, actioned) {
        case (.commit, false): return "Commit"
        case (.commit, true): return "Committed"
        case (.tag, false): return "Create Tag"
        case (.tag, true): return "Tagged"
        }
    }

    private func performAction(for message: ChatMessage) {
        switch mode {
        case .commit: performCommit(for: message)
        case .tag: performCreateTag(for: message)
        }
    }

    private func loadContext() {
        switch mode {
        case .commit:
            stagedDiff = gitService.stagedDiff()
            if !stagedDiff.isEmpty {
                isInputFocused = true
            }
        case .tag:
            let context = gitService.commitsSinceLastTag()
            tagLastTag = context.lastTag
            tagCommitLog = context.log
            if !tagCommitLog.isEmpty {
                isInputFocused = true
            }
        }
    }

    private func stageAll() {
        gitService.stageAll()
        loadContext()
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

        let systemPrompt = mode == .commit ? commitSystemPrompt : tagSystemPrompt

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

    private var commitSystemPrompt: String {
        """
        You are a git commit message generator. Follow Conventional Commits strictly.

        Allowed <type> values (pick exactly one): feat, fix, docs, style, refactor, perf, test, chore, build, ci, revert.

        Output exactly this and nothing else — no markdown fences, no preamble, no explanation:

        <type>(<scope>): <imperative summary, max 72 chars, lowercase, no trailing period>

        <body: 1-3 short sentences in plain prose explaining what changed and why>

        Rules:
        - <scope> is optional; if there's no clear scope, omit the parentheses entirely (e.g. "fix: handle nil response").
        - Summary must be imperative mood ("add", not "added"/"adds").
        - Never wrap the output in ``` code fences.
        - Only include a "BREAKING CHANGE:" footer if the diff clearly breaks a public API/contract.
        - Trivial diffs (whitespace, comments, formatting) should still be classified correctly — usually "chore" or "style".

        Diff:
        \(stagedDiff)
        """
    }

    private var tagSystemPrompt: String {
        let baseVersion = tagLastTag ?? "none (this is the first release)"
        return """
        You are a release-notes generator for annotated git tags. You receive the commit list since the last tag.

        Output exactly this and nothing else — no markdown fences, no preamble:

        v<major>.<minor>.<patch>

        <changelog body>

        Version bump rules (base version: \(baseVersion)):
        - MAJOR if any commit contains "BREAKING CHANGE" or "!" after type/scope (e.g. "feat!:").
        - Else MINOR if any commit type is "feat".
        - Else PATCH if any commit type is "fix".
        - Else PATCH by default.
        - If there is no previous tag, start at v0.1.0 unless commits indicate a stable v1.0.0 release.

        Changelog body rules:
        - Group entries under headings, only include a heading if it has at least one entry: "### Added", "### Fixed", "### Changed", "### Other".
        - Mapping: feat → Added, fix → Fixed, refactor/perf/style/chore/docs/build/ci → Changed, revert → Other.
        - One "- " bullet per commit, plain language, imperative, not a verbatim copy of the commit subject if it's unclear.

        Commits since \(baseVersion):
        \(tagCommitLog)
        """
    }

    private func regenerate() {
        guard !isStreaming else { return }
        if let lastAssistantIndex = messages.lastIndex(where: { $0.role == "assistant" }) {
            messages.removeSubrange(lastAssistantIndex...)
        }
        guard messages.last?.role == "user" else { return }
        generateResponse()
    }

    private func beginEdit(_ message: ChatMessage) {
        guard !isStreaming else { return }
        editDraft = message.content
        editingMessageId = message.id
    }

    private func cancelEdit() {
        editingMessageId = nil
        editDraft = ""
    }

    private func saveEdit(for message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let newText = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return }

        messages[index].content = newText
        if messages.count > index + 1 {
            messages.removeSubrange((index + 1)...)
        }

        editingMessageId = nil
        editDraft = ""
        generateResponse()
    }

    @ViewBuilder
    private func editingBubble(_ message: ChatMessage) -> some View {
        HStack(spacing: 6) {
            TextField("Edit message...", text: $editDraft)
                .textFieldStyle(.plain)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                )
                .onSubmit { saveEdit(for: message) }

            Button(action: { saveEdit(for: message) }) {
                Image(systemName: "checkmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Button(action: cancelEdit) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func performCommit(for message: ChatMessage) {
        do {
            try gitService.commit(message: message.content)
            actionedMessageIds.insert(message.id)
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

    private func performCreateTag(for message: ChatMessage) {
        guard let parsed = parseTagOutput(message.content) else {
            withAnimation(.easeOut(duration: 0.2)) {
                messages.append(ChatMessage(role: "system", content: "❌ Could not parse a tag name from the response"))
            }
            return
        }

        do {
            try gitService.createAnnotatedTag(name: parsed.name, message: parsed.message)
            actionedMessageIds.insert(message.id)
            withAnimation(.easeOut(duration: 0.2)) {
                messages.append(ChatMessage(role: "system", content: "✅ Created tag \(parsed.name)"))
            }
        } catch {
            let reason = (error as? GitTagError)?.errorDescription ?? error.localizedDescription
            withAnimation(.easeOut(duration: 0.2)) {
                messages.append(ChatMessage(role: "system", content: "❌ Tag creation failed: \(reason)"))
            }
        }
    }

    private func parseTagOutput(_ content: String) -> (name: String, message: String)? {
        let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstLine = parts.first else { return nil }

        let name = firstLine.trimmingCharacters(in: .whitespaces)
        guard name.hasPrefix("v"), name.count > 1 else { return nil }

        let rest = parts.count > 1 ? String(parts[1]) : ""
        let message = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, message.isEmpty ? name : message)
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
