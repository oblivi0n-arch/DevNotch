import SwiftUI

private enum ChatMode: String, CaseIterable, Identifiable {
    case commit = "Commit"
    case tag = "Tag"

    var id: String { rawValue }
}

private struct PreparedTag {
    let name: String
    let message: String
}

@MainActor
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
    @State private var isPerformingAction = false
    @State private var preparedTags: [UUID: PreparedTag] = [:]

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
                .disabled(isStreaming)
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
                    .disabled(alreadyActioned || isPerformingAction)

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
        .task {
            await loadContext()
        }
        .onChange(of: mode) {
            Task { await loadContext() }
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

    @MainActor
    private func loadContext() async {
        switch mode {
        case .commit:
            stagedDiff = await gitService.stagedDiff()
            if !stagedDiff.isEmpty {
                isInputFocused = true
            }
        case .tag:
            let context = await gitService.commitsSinceLastTag()
            tagLastTag = context.lastTag
            tagCommitLog = context.log
            if !tagCommitLog.isEmpty {
                isInputFocused = true
            }
        }
    }

    @MainActor
    private func stageAll() {
        Task {
            await gitService.stageAll()
            await loadContext()
        }
    }

    private func send() {
        let userText = draft
        draft = ""
        withAnimation(.easeOut(duration: 0.2)) {
            messages.append(ChatMessage(role: "user", content: userText))
        }
        generateResponse()
    }

    @MainActor
    private func generateResponse() {
        lastError = nil
        withAnimation(.easeOut(duration: 0.2)) {
            messages.append(ChatMessage(role: "assistant", content: ""))
        }
        isStreaming = true

        let systemPrompt = mode == .commit ? commitSystemPrompt : tagSystemPrompt
        var history: [OllamaMessage] = [OllamaMessage(role: "system", content: systemPrompt)]
        history += messages.dropLast()
            .filter { $0.role == "user" || $0.role == "assistant" }
            .map { OllamaMessage(role: $0.role, content: $0.content) }

        let currentMode = mode
        let baseTag = tagLastTag

        Task {
            do {
                let rendered: String
                var prepared: PreparedTag?

                switch currentMode {
                case .commit:
                    let draft = try await client.complete(
                        CommitDraft.self,
                        messages: history,
                        schema: CommitDraft.jsonSchema
                    )
                    rendered = draft.renderedMessage

                case .tag:
                    let draft = try await client.complete(
                        TagDraft.self,
                        messages: history,
                        schema: TagDraft.jsonSchema
                    )
                    let version = SemanticVersion.next(after: baseTag, bump: draft.bump)
                    prepared = PreparedTag(name: version.tagName, message: draft.changelog)
                    rendered = "\(version.tagName)\n\n\(draft.changelog)"
                }

                guard let index = messages.indices.last else {
                    isStreaming = false
                    return
                }
                messages[index].content = rendered
                if let prepared {
                    preparedTags[messages[index].id] = prepared
                }
                isStreaming = false

            } catch {
                messages.removeLast()
                lastError = (error as? OllamaError) ?? .connectionFailed
                isStreaming = false
            }
        }
    }
    
    private var commitSystemPrompt: String {
        """
        ROLE
        You classify a git diff into exactly one Conventional Commits type and write a concise message. Your answer is returned as JSON matching a fixed schema — never write prose outside the fields.

        FIELD RULES
        - type: exactly one allowed value; pick the single best fit.
        - scope: one lowercase word naming the affected area, or "" if unclear.
        - summary: imperative mood, lowercase, no trailing period, max 60 characters.
        - body: 1-3 plain-prose sentences on what changed and why. Never restate the diff.
        - breakingChange: "" unless the diff changes a contract something else depends on directly — a function signature, a persisted data format, a config key or file, a CLI argument, an exposed API. An internal-only change is never breaking on its own, even if behavior changes meaningfully.

        TYPE DEFINITIONS
        - feat: adds or changes a capability observable at runtime — a new trigger, a new condition under which something starts/stops, a new state, a new user-facing behavior. Applies even when implemented by editing an existing function.
        - fix: corrects behavior that was wrong relative to intent — a bug, crash, wrong output, wrong state, incorrect condition.
        - perf: same external behavior, lower cost — CPU, memory, network calls, disk I/O, polling frequency, algorithmic complexity.
        - refactor: restructures code with NO change to external behavior and NO resource intent.
        - style: zero-semantic formatting only — whitespace, indentation, import ordering, linter fixes.
        - docs: changes confined to documentation or comments.
        - test: changes confined to test code, fixtures, or mocks.
        - chore: repository maintenance with no user-facing or architectural significance.
        - build: changes to the build/packaging system or its dependencies.
        - ci: changes to CI/CD pipeline configuration.
        - revert: undoes a previous commit.

        DISAMBIGUATION
        - feat vs fix: working-as-designed + new capability → feat. Behavior diverged from intent → fix.
        - feat vs refactor: diff changes when/how/whether something runs → feat, never refactor, no matter how much code was touched.
        - perf vs refactor: motivation is reducing resource usage or call frequency → perf, never refactor.
        - perf vs fix: prior behavior correct but wasteful → perf. Prior behavior incorrect → fix.
        - chore vs build vs ci: chore = housekeeping unrelated to compiling/pipelines; build = compilation/packaging/dependencies; ci = pipeline config.
        - style vs refactor: style is provably zero-semantic; anything reorganizing logic is refactor.
        - Mixed diffs: classify by primary intent, not by which files were touched.

        DIFF
        \(stagedDiff)
        """
    }

    private var tagSystemPrompt: String {
        let baseVersion = tagLastTag ?? "none (this is the first release)"
        return """
        ROLE
        You turn a list of commit subjects into a release changelog. Your answer is returned as JSON matching a fixed schema — never write prose outside the fields.

        The version number is computed by the application, not by you. You only decide how large the bump is.

        FIELD RULES
        - bump:
          - "major" if any commit carries a "BREAKING CHANGE:" footer or a "!" after the type/scope (e.g. "feat!:").
          - otherwise "minor" if at least one commit has type "feat".
          - otherwise "patch".
          Multiple breaking changes in the same range still produce a single bump.
        - added: one entry per "feat" commit.
        - fixed: one entry per "fix" commit.
        - performance: one entry per "perf" commit.
        - changed: one entry per refactor/style/docs/build/ci/chore commit.
        - other: one entry per revert or test-only commit.

        Entries are plain language and imperative, in commit order (oldest first). Never merge two commits into one entry. If a commit subject is cryptic, rewrite it so a user understands it. Leave an array empty when no commit matches it.

        COMMITS SINCE \(baseVersion)
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

    @MainActor
    private func performCommit(for message: ChatMessage) {
        guard !isPerformingAction else { return }
        isPerformingAction = true

        Task {
            defer { isPerformingAction = false }
            do {
                try await gitService.commit(message: message.content)
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
    }

    @MainActor
    private func performCreateTag(for message: ChatMessage) {
        guard let prepared = preparedTags[message.id] else {
            withAnimation(.easeOut(duration: 0.2)) {
                messages.append(ChatMessage(role: "system", content: "❌ No version prepared for this response"))
            }
            return
        }

        guard !isPerformingAction else { return }
        isPerformingAction = true

        Task {
            defer { isPerformingAction = false }
            do {
                try await gitService.createAnnotatedTag(name: prepared.name, message: prepared.message)
                actionedMessageIds.insert(message.id)
                withAnimation(.easeOut(duration: 0.2)) {
                    messages.append(ChatMessage(role: "system", content: "✅ Created tag \(prepared.name)"))
                }
            } catch {
                let reason = (error as? GitTagError)?.errorDescription ?? error.localizedDescription
                withAnimation(.easeOut(duration: 0.2)) {
                    messages.append(ChatMessage(role: "system", content: "❌ Tag creation failed: \(reason)"))
                }
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
}
