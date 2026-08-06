import SwiftUI

struct OllamaChatView: View {
    @ObservedObject var gitService: GitStatusService

    @State private var messages: [ChatMessage] = []
    @State private var draft: String = ""
    @State private var stagedDiff: String = ""
    @State private var isStreaming = false
    
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        Text(message.content)
                            .padding(8)
                            .background(message.role == "user" ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
                            .cornerRadius(8)
                            .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                    }
                }
                .padding(8)
            }

            if let lastAssistant = messages.last(where: { $0.role == "assistant" }), !isStreaming {
                Button("Commit this message") {
                    gitService.commit(message: lastAssistant.content)
                }
                .padding(.bottom, 8)
            }

            Divider()

            HStack {
                TextField("Describe your change...", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(stagedDiff.isEmpty || isStreaming)
                    .onSubmit(send)
                    .focused($isInputFocused)

                Button("Send", action: send)
                    .disabled(draft.isEmpty || isStreaming || stagedDiff.isEmpty)
            }
            .padding(8)
        }
        .frame(width: 320, height: 400)
        .onAppear(perform: loadDiff)
    }

    private func loadDiff() {
        stagedDiff = gitService.stagedDiff()
        if stagedDiff.isEmpty {
            messages = [ChatMessage(role: "system", content: "No staged changes. Run git add first.")]
        } else {
            isInputFocused = true
        }
    }

    private func send() {
        let userText = draft
        draft = ""
        messages.append(ChatMessage(role: "user", content: userText))
        messages.append(ChatMessage(role: "assistant", content: ""))
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
        history += messages.dropLast().map { OllamaMessage(role: $0.role, content: $0.content) }

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
                    if let lastIndex = messages.indices.last {
                        messages[lastIndex].content = "Error: \(error.localizedDescription)"
                    }
                }
            }
            await MainActor.run { isStreaming = false }
        }
    }
}
