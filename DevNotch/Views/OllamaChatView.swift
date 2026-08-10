import SwiftUI

private enum ChatMode: String, CaseIterable, Identifiable {
    case commit = "Commit"
    case tag = "Tag"

    var id: String { rawValue }
}

private struct Feedback {
    let text: String
    let isError: Bool
}

@MainActor
struct OllamaChatView: View {
    @ObservedObject var gitService: GitStatusService

    @State private var mode: ChatMode = .commit
    @State private var note: String = ""

    @State private var commitDraft: CommitDraft?
    @State private var releaseNotes: ReleaseNotes?
    @State private var bumpOverride: VersionBump?

    @State private var stagedDiff: String = ""
    @State private var tagLastTag: String?
    @State private var tagCommits: [ParsedCommit] = []

    @State private var isGenerating = false
    @State private var isPerformingAction = false
    @State private var didAction = false
    @State private var lastError: OllamaError?
    @State private var feedback: Feedback?
    @State private var contentHeight: CGFloat = 0

    @FocusState private var isInputFocused: Bool

    private let client = OllamaClient()

    private let popoverWidth: CGFloat = 360
    private let minContentHeight: CGFloat = 96
    private let maxContentHeight: CGFloat = 360

    // MARK: - Derived context

    private var contextIsEmpty: Bool {
        switch mode {
        case .commit: return stagedDiff.isEmpty
        case .tag: return tagCommits.isEmpty
        }
    }

    private var stagedFileCount: Int {
        guard !stagedDiff.isEmpty else { return 0 }
        return stagedDiff.components(separatedBy: "diff --git ").count - 1
    }

    private var commitCount: Int { tagCommits.count }

    private var effectiveBump: VersionBump? {
        guard !tagCommits.isEmpty else { return nil }
        return bumpOverride ?? ReleaseNotes.bump(for: tagCommits)
    }

    private var nextVersion: SemanticVersion? {
        guard let effectiveBump else { return nil }
        return version(for: effectiveBump)
    }

    private func version(for bump: VersionBump) -> SemanticVersion {
        SemanticVersion.next(after: tagLastTag, bump: bump)
    }

    private func suggestedBump(from computed: VersionBump) -> VersionBump {
        guard computed == .major else { return computed }

        let currentMajor = tagLastTag.flatMap(SemanticVersion.init(tag:))?.major ?? 0
        return currentMajor == 0 ? .minor : .major
    }

    private var hasDraft: Bool {
        mode == .commit ? commitDraft != nil : releaseNotes != nil
    }

    private var headline: String {
        switch mode {
        case .commit:
            let branch = gitService.status.branch
            return branch.isEmpty ? "No repository" : branch
        case .tag:
            let base = tagLastTag ?? "the start"
            return commitCount == 1 ? "1 commit since \(base)" : "\(commitCount) commits since \(base)"
        }
    }

    private var contextDetail: String? {
        guard mode == .commit, stagedFileCount > 0 else { return nil }
        return stagedFileCount == 1 ? "1 staged" : "\(stagedFileCount) staged"
    }

    private var inputPlaceholder: String {
        mode == .commit ? "Add context…" : "Add release context…"
    }

    private var primaryActionLabel: String {
        switch (mode, didAction) {
        case (.commit, false): return "Commit"
        case (.commit, true): return "Committed"
        case (.tag, false): return nextVersion.map { "Create tag \($0.tagName)" } ?? "Create tag"
        case (.tag, true): return "Tagged"
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            modeTabs
            Divider()

            ScrollView {
                contentSection
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        contentHeight = height
                    }
            }
            .frame(height: min(max(contentHeight, minContentHeight), maxContentHeight))

            if let feedback {
                feedbackRow(feedback)
            }

            if hasDraft && !isGenerating {
                actionBar
            }

            Divider()
            inputBar
        }
        .frame(width: popoverWidth)
        .task {
            await refresh()
        }
        .onChange(of: mode) {
            Task { await refresh() }
        }
    }

    // MARK: - Chrome

    private var contextBar: some View {
        HStack(spacing: 7) {
            Image(systemName: mode == .commit ? "arrow.triangle.branch" : "tag")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(headline)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let contextDetail {
                Text(contextDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var modeTabs: some View {
        HStack(spacing: 18) {
            ForEach(ChatMode.allCases) { item in
                Button {
                    mode = item
                } label: {
                    VStack(spacing: 6) {
                        Text(item.rawValue)
                            .font(.system(size: 12, weight: mode == item ? .medium : .regular))
                            .foregroundStyle(mode == item ? Color.primary : Color.secondary)
                        Rectangle()
                            .fill(mode == item ? Color.primary : Color.clear)
                            .frame(height: 1.5)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: performPrimaryAction) {
                Text(primaryActionLabel)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(didAction || isPerformingAction)

            Button {
                Task { await generate() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .disabled(isPerformingAction)
            .help("Regenerate")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(inputPlaceholder, text: $note)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isInputFocused)
                .onSubmit { Task { await generate() } }
                .disabled(contextIsEmpty || isGenerating)

            Button {
                Task { await generate() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .disabled(contextIsEmpty || isGenerating)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private func feedbackRow(_ feedback: Feedback) -> some View {
        HStack(spacing: 6) {
            Image(systemName: feedback.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(feedback.isError ? Color.red : Color.green)
            Text(feedback.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        if contextIsEmpty {
            emptyState
        } else if isGenerating {
            generatingState
        } else if let lastError {
            errorState(lastError)
        } else if mode == .commit, let commitDraft {
            commitCard(commitDraft)
        } else if mode == .tag, let releaseNotes {
            tagCard(releaseNotes)
        } else {
            idleState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: mode == .commit ? "tray" : "tag")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(mode == .commit ? "Nothing staged" : "No commits since the last tag")
                .font(.system(size: 12, weight: .medium))
            Text(mode == .commit ? "Stage the changes you want to describe" : "Commit some changes first")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if mode == .commit {
                Button("Stage all") {
                    Task {
                        await gitService.stageAll()
                        await refresh()
                    }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var generatingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(mode == .commit ? "Reading the diff…" : "Reading the commit log…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var idleState: some View {
        Text("Nothing generated yet")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
    }

    private func errorState(_ error: OllamaError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error.errorDescription ?? "Something went wrong")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button("Try again") {
                Task { await generate() }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func commitCard(_ draft: CommitDraft) -> some View {
        let subject = draft.subjectLine

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(draft.type.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)

                if !draft.scope.isEmpty {
                    Text(draft.scope)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text("\(subject.count) chars")
                    .font(.system(size: 11))
                    .foregroundStyle(subject.count > 72 ? Color.orange : Color.secondary)
            }

            Text(subject)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !draft.body.isEmpty {
                Text(draft.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !draft.breakingChange.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(draft.breakingChange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func tagCard(_ notes: ReleaseNotes) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(tagLastTag ?? "start")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(nextVersion?.tagName ?? "—")
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                ForEach(VersionBump.allCases, id: \.self) { bump in
                    Button {
                        bumpOverride = bump
                    } label: {
                        Text(bump.rawValue)
                            .font(.system(size: 11))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(effectiveBump == bump ? Color.primary.opacity(0.08) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        Color.secondary.opacity(effectiveBump == bump ? 0.55 : 0.22),
                                        lineWidth: 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            ForEach(notes.sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    ForEach(section.entries, id: \.self) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            Text(entry)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: - Work

    private func refresh() async {
        commitDraft = nil
        releaseNotes = nil
        bumpOverride = nil
        didAction = false
        feedback = nil
        lastError = nil

        switch mode {
        case .commit:
            stagedDiff = await gitService.stagedDiff()
        case .tag:
            let context = await gitService.commitsSinceLastTag()
            tagLastTag = context.lastTag
            tagCommits = context.commits
        }

        guard !contextIsEmpty else { return }
        isInputFocused = true
        await generate()
    }

    private func generate() async {
        guard !contextIsEmpty, !isGenerating else { return }

        isGenerating = true
        lastError = nil
        feedback = nil
        didAction = false
        bumpOverride = nil

        var request = [OllamaMessage(
            role: "system",
            content: mode == .commit ? commitSystemPrompt : tagSystemPrompt
        )]

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            request.append(OllamaMessage(role: "user", content: trimmedNote))
        }

        do {
            switch mode {
            case .commit:
                commitDraft = try await client.complete(
                    CommitDraft.self,
                    messages: request,
                    schema: CommitDraft.jsonSchema
                )
            case .tag:
                let draft = try await client.complete(
                    ReleaseNotesDraft.self,
                    messages: request,
                    schema: ReleaseNotesDraft.jsonSchema
                )
                releaseNotes = ReleaseNotes.build(commits: tagCommits, rewritten: draft.entries)
                bumpOverride = suggestedBump(from: ReleaseNotes.bump(for: tagCommits))
            }
        } catch {
            lastError = (error as? OllamaError) ?? .connectionFailed
        }

        isGenerating = false
    }

    private func performPrimaryAction() {
        switch mode {
        case .commit: performCommit()
        case .tag: performCreateTag()
        }
    }

    private func performCommit() {
        guard let commitDraft, !isPerformingAction else { return }
        isPerformingAction = true

        Task {
            defer { isPerformingAction = false }
            do {
                try await gitService.commit(message: commitDraft.renderedMessage)
                didAction = true
                feedback = Feedback(text: "Committed to \(gitService.status.branch)", isError: false)
            } catch {
                let reason = (error as? GitCommitError)?.errorDescription ?? error.localizedDescription
                feedback = Feedback(text: reason, isError: true)
            }
        }
    }

    private func performCreateTag() {
        guard let releaseNotes, let nextVersion, !isPerformingAction else { return }
        isPerformingAction = true

        Task {
            defer { isPerformingAction = false }
            do {
                try await gitService.createAnnotatedTag(
                    name: nextVersion.tagName,
                    message: releaseNotes.markdown
                )
                didAction = true
                feedback = Feedback(text: "Created tag \(nextVersion.tagName)", isError: false)
            } catch {
                let reason = (error as? GitTagError)?.errorDescription ?? error.localizedDescription
                feedback = Feedback(text: reason, isError: true)
            }
        }
    }

    // MARK: - Prompts

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
        let numbered = tagCommits
            .enumerated()
            .map { index, commit in "\(index + 1). \(commit.subject)" }
            .joined(separator: "\n")

        return """
        ROLE
        You rewrite git commit subjects into release note entries. Your answer is returned as JSON matching a fixed schema — never write prose outside the fields.

        You do not classify anything and you do not decide the version. The application already knows the type of every commit from its prefix and computes the version itself. Your only job is wording.

        RULES
        - Return exactly \(tagCommits.count) \(tagCommits.count == 1 ? "entry" : "entries"), one per numbered commit below, in the same order.
        - Never merge two commits into one entry, never drop one, never add one.
        - Each entry is a single sentence in plain language, imperative mood, understandable to someone who has not read the code.
        - Drop the conventional-commit prefix and scope; keep only the meaning.
        - Do not invent changes that are not in the list, and do not restate a subject verbatim if it is cryptic — explain it.

        COMMITS (oldest first)
        \(numbered)
        """
    }
}
