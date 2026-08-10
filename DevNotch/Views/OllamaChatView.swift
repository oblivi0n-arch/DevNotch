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
    @State private var autoRetryCount = 0
    @State private var isPerformingAction = false

    @FocusState private var isInputFocused: Bool

    private let client = OllamaClient()
    private let maxAutoRetries = 2
    private static let allowedCommitTypes = [
        "feat", "fix", "docs", "style", "refactor", "perf", "test", "chore", "build", "ci", "revert"
    ]

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
                await MainActor.run {
                    handleGenerationFinished()
                }
            } catch {
                await MainActor.run {
                    messages.removeLast()
                    lastError = (error as? OllamaError) ?? .connectionFailed
                    isStreaming = false
                    autoRetryCount = 0
                }
            }
        }
    }

    private func handleGenerationFinished() {
        guard let last = messages.last, last.role == "assistant", !last.content.isEmpty else {
            isStreaming = false
            autoRetryCount = 0
            return
        }

        if isValidOutput(last.content) {
            isStreaming = false
            autoRetryCount = 0
            return
        }

        guard autoRetryCount < maxAutoRetries else {
            isStreaming = false
            autoRetryCount = 0
            withAnimation(.easeOut(duration: 0.2)) {
                messages.append(ChatMessage(role: "system", content: "⚠️ Response format looks off after \(maxAutoRetries) retries — review it before using it"))
            }
            return
        }

        autoRetryCount += 1
        if let lastAssistantIndex = messages.lastIndex(where: { $0.role == "assistant" }) {
            messages.removeSubrange(lastAssistantIndex...)
        }
        generateResponse()
    }

    private func isValidOutput(_ content: String) -> Bool {
        switch mode {
        case .commit: return isValidCommitOutput(content)
        case .tag: return isValidTagOutput(content)
        }
    }

    private func isValidCommitOutput(_ content: String) -> Bool {
        guard !content.contains("```") else { return false }
        guard let firstLine = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return false
        }
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard let colonIndex = line.firstIndex(of: ":") else { return false }

        let head = String(line[line.startIndex..<colonIndex])
        let type = head.contains("(") ? String(head[..<head.firstIndex(of: "(")!]) : head

        guard Self.allowedCommitTypes.contains(type) else { return false }
        guard line.count <= 100 else { return false }
        return true
    }

    private func isValidTagOutput(_ content: String) -> Bool {
        guard !content.contains("```") else { return false }
        return parseTagOutput(content) != nil
    }

    private var commitSystemPrompt: String {
        """
        ROLE
        You are a git commit message generator for a single developer's private project. You classify a diff into exactly one Conventional Commits type and write a concise message. The rules below are the highest priority — follow them even when the example seems to suggest otherwise.

        RULES (apply in this order)

        1. Allowed types (pick exactly one): feat, fix, docs, style, refactor, perf, test, chore, build, ci, revert.

        2. Type definitions:
           - feat: adds or changes a capability observable at runtime — a new trigger, a new condition under which something starts/stops, a new state, a new user-facing behavior. Applies even when implemented by editing an existing function rather than adding a new symbol.
           - fix: corrects behavior that was wrong relative to what the code was supposed to do — a bug, crash, wrong output, wrong state, incorrect condition.
           - perf: keeps external behavior the same but reduces cost — CPU, memory, network calls, disk I/O, polling frequency, algorithmic complexity. Same result, cheaper.
           - refactor: restructures code with NO change to external behavior and NO resource/performance intent.
           - style: zero-semantic formatting only — whitespace, indentation, import ordering, linter fixes.
           - docs: changes confined to documentation/comments/README with no code semantics touched.
           - test: changes confined to test code, fixtures, or mocks.
           - chore: repository maintenance with no user-facing or architectural significance.
           - build: changes to the build/packaging system or its dependencies.
           - ci: changes to CI/CD pipeline configuration.
           - revert: undoes a previous commit.

        3. Disambiguation (use when two types both seem plausible):
           - feat vs fix: working-as-designed + new capability → feat. Behavior diverged from intent → fix.
           - feat vs refactor: diff changes when/how/whether something runs → feat, never refactor, no matter how much existing code was touched.
           - perf vs refactor: diff's motivation is reducing resource usage or call frequency → perf, never refactor.
           - perf vs fix: prior behavior correct but wasteful/slow → perf. Prior behavior incorrect or crashing → fix.
           - chore vs build vs ci: chore = general housekeeping unrelated to compiling/pipelines; build = compilation/packaging/dependencies; ci = pipeline automation config.
           - style vs refactor: style is provably zero-semantic; anything reorganizing logic is refactor.
           - docs vs chore: docs = documentation content itself; chore = non-documentation maintenance.
           - Mixed diffs: classify by the primary intent, not by which files were touched.

        4. BREAKING CHANGE footer: only add it when the diff changes a contract something else depends on directly — a function/method signature, a persisted data format, a config key or file, a CLI argument, an exposed API/endpoint. An internal-only change is never breaking on its own, even if behavior changes meaningfully.

        5. Style constraints: imperative mood, lowercase after the colon, max 72 chars, no trailing period, no markdown code fences. <scope> optional — omit parentheses if unclear. Body is 1-3 plain-prose sentences.

        OUTPUT FORMAT
        Produce exactly two parts and nothing else — no preamble, no restated diff, no explanation of your reasoning:

        <type>(<scope>): <summary>

        <body>

        ---
        EXAMPLE (format reference only — do not reuse its content)

        Diff:
        diff --git a/Sources/Utils/Formatter.swift b/Sources/Utils/Formatter.swift
        index 83f3b19..4c7a2ee 100644
        --- a/Sources/Utils/Formatter.swift
        +++ b/Sources/Utils/Formatter.swift
        @@ -12,6 +12,9 @@ struct Formatter {
        +    static func trimmed(_ text: String) -> String {
        +        text.trimmingCharacters(in: .whitespacesAndNewlines)
        +    }

        Correct output for that diff:
        feat(utils): add trimmed string formatting helper

        Adds a helper that strips leading/trailing whitespace and newlines from a string, used by the commit preview to avoid stray blank lines.

        ---
        TASK
        Classify and write a commit message for the diff below. Output only the two parts described in OUTPUT FORMAT.

        Diff:
        \(stagedDiff)
        """
    }

    private var tagSystemPrompt: String {
        let baseVersion = tagLastTag ?? "none (this is the first release)"
        return """
        ROLE
        You are a release-notes and version generator for annotated git tags, working from the commit list since the last tag. The rules below are the highest priority — follow them even when the example seems to suggest otherwise.

        RULES (apply in this order)

        1. Version bump logic (base version: \(baseVersion)):
           - MAJOR if any commit has a "BREAKING CHANGE:" footer or "!" after type/scope (e.g. "feat!:") — UNLESS base version is 0.x.y (pre-1.0), in which case this bumps MINOR instead (SemVer initial-development convention).
           - Else MINOR if at least one commit has type "feat".
           - Else PATCH if at least one commit has type "fix" or "perf".
           - Else PATCH by default if there are any commits at all (only refactor/test/chore/build/ci/style/docs/revert) — still bump, and note in the body that this release has no user-facing changes.
           - Multiple breaking changes in the same range still produce a single bump, never multiple.
           - No previous tag → start at v0.1.0, unless commits explicitly indicate a stable v1.0.0 release.

        2. Changelog body logic:
           - Group under headings, only if they have at least one entry: "### Added" (feat), "### Fixed" (fix), "### Performance" (perf), "### Changed" (refactor/style/docs/build/ci/chore), "### Other" (revert, test-only).
           - One "- " bullet per commit, plain language, imperative. Keep bullets in commit order (oldest first) within each heading. Never merge two commits into one bullet.
           - If only refactor/test/chore/build/ci/style/docs commits exist, still produce a body — never an empty one.

        3. Style constraints: no markdown code fences, no restating the input commit list, no explanation of your reasoning.

        OUTPUT FORMAT
        Produce exactly two parts and nothing else — no preamble:

        v<major>.<minor>.<patch>

        <changelog body>

        ---
        EXAMPLE (format reference only — do not reuse its content)

        Commits since v1.2.0:
        feat(chat): add regenerate button
        fix(git): handle missing upstream branch
        docs(readme): clarify setup steps

        Correct output for that commit list:
        v1.3.0

        ### Added
        - Regenerate button to reroll the last generated response

        ### Fixed
        - Missing upstream branch no longer crashes status refresh

        ### Changed
        - Clarified setup steps in the README

        ---
        TASK
        Generate the version and changelog for the commits below. Output only the two parts described in OUTPUT FORMAT.

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
        guard let parsed = parseTagOutput(message.content) else {
            withAnimation(.easeOut(duration: 0.2)) {
                messages.append(ChatMessage(role: "system", content: "❌ Could not parse a tag name from the response"))
            }
            return
        }

        guard !isPerformingAction else { return }
        isPerformingAction = true

        Task {
            defer { isPerformingAction = false }
            do {
                try await gitService.createAnnotatedTag(name: parsed.name, message: parsed.message)
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
    }

    private func parseTagOutput(_ content: String) -> (name: String, message: String)? {
        let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstLine = parts.first else { return nil }

        let name = firstLine.trimmingCharacters(in: .whitespaces)
        guard GitStatusService.isValidTagName(name) else { return nil }

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
