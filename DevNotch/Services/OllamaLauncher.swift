import Foundation

@MainActor
final class OllamaLauncher {
    static let shared = OllamaLauncher()

    private var process: Process?
    private var didStartProcess = false

    private init() {}

    private static let candidatePaths = [
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama"
    ]

    private var pidFileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("DevNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ollama.pid")
    }

    private func savePid(_ pid: Int32) {
        try? String(pid).write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func clearPidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func readSavedPid() -> Int32? {
        guard let content = try? String(contentsOf: pidFileURL, encoding: .utf8) else { return nil }
        return Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isRunningOllamaProcess(pid: Int32) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.contains("ollama")
    }

    private func cleanupOrphanIfNeeded() {
        guard let pid = readSavedPid() else { return }

        if isRunningOllamaProcess(pid: pid) {
            kill(pid, SIGTERM)
        }
        clearPidFile()
    }

    func startIfNeeded() async {
        cleanupOrphanIfNeeded()

        guard UserDefaults.standard.bool(forKey: "autoStartOllama") else { return }
        guard await !isServerReachable() else { return }

        let manualPath = UserDefaults.standard.string(forKey: "ollamaExecutablePath") ?? ""
        let resolvedPath: String?

        if !manualPath.isEmpty, FileManager.default.isExecutableFile(atPath: manualPath) {
            resolvedPath = manualPath
        } else {
            resolvedPath = Self.candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        }

        guard let path = resolvedPath else { return }
        launch(at: path)
    }

    private func isServerReachable() async -> Bool {
        let host = UserDefaults.standard.string(forKey: "ollamaHost") ?? OllamaDefaults.host
        guard let url = URL(string: host) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        return (try? await URLSession.shared.data(for: request)) != nil
    }

    private func launch(at path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["serve"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            process = task
            didStartProcess = true
            savePid(task.processIdentifier)
        } catch {

        }
    }

    func stopIfWeStartedIt() {
        guard didStartProcess, let process, process.isRunning else { return }
        process.terminate()
        clearPidFile()
    }
}
