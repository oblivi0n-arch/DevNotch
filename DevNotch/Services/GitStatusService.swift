import Foundation
import AppKit
import Combine

struct GitStatus: Equatable {
    var branch: String = ""
    var uncommittedChanges: Int = 0
    var lastTag: String = ""
    var repoPath: String = ""
    var isValidRepo: Bool = false
    var hasUpstream: Bool = false
    var aheadCount: Int = 0
    var behindCount: Int = 0
}

final class GitStatusService: ObservableObject {
    @Published private(set) var status = GitStatus()

    private let appModeService: AppModeService
    private var modeCancellable: AnyCancellable?

    private var currentRepoPath: String?
    private var eventStream: FSEventStreamRef?
    private var refreshWorkItem: DispatchWorkItem?
    private let gitQueue = DispatchQueue(label: "devnotch.git", qos: .utility)

    private var safetyNetTimer: Timer?

    private var didStart = false

    init(appModeService: AppModeService) {
        self.appModeService = appModeService
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        modeCancellable = appModeService.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeActiveRepo()
            }

        safetyNetTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.recomputeActiveRepo()
        }

        DispatchQueue.main.async { [weak self] in
            self?.recomputeActiveRepo()
        }
    }

    deinit {
        safetyNetTimer?.invalidate()
        stopWatchingRepo()
    }

    private func recomputeActiveRepo() {
        guard case .dev(let devApp) = appModeService.mode,
              let frontApp = NSWorkspace.shared.frontmostApplication else { return }

        let terminalPID = frontApp.processIdentifier

        gitQueue.async { [weak self] in
            guard let self = self else { return }

            let resolvedPath: String? = devApp == .xcode
                ? self.resolveXcodeRepoPath()
                : self.resolveTerminalRepoPath(terminalPID: terminalPID)

            guard let path = resolvedPath, path != self.currentRepoPath else { return }

            self.currentRepoPath = path
            self.watchRepo(at: path)
            self.refreshStatus(at: path)
        }
    }

    private func resolveTerminalRepoPath(terminalPID: pid_t) -> String? {
        let snapshot = ProcessInspector.snapshotAllProcesses()
        guard let shellPID = ProcessInspector.findShellPID(startingAt: terminalPID, in: snapshot),
              let cwd = ProcessInspector.currentWorkingDirectory(of: shellPID) else {
            return nil
        }
        return findRepoRoot(startingAt: URL(fileURLWithPath: cwd)) ?? cwd
    }

    private func resolveXcodeRepoPath() -> String? {
        let script = """
        tell application "Xcode"
            if not (exists active workspace document) then return ""
            return path of active workspace document
        end tell
        """

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else { return nil }
        let output = scriptObject.executeAndReturnError(&error)

        if error != nil { return nil }

        guard let projectPath = output.stringValue, !projectPath.isEmpty else { return nil }

        let projectURL = URL(fileURLWithPath: projectPath)
        return findRepoRoot(startingAt: projectURL.deletingLastPathComponent())
    }

    private func findRepoRoot(startingAt url: URL, maxLevels: Int = 6) -> String? {
        var current = url
        for _ in 0..<maxLevels {
            let gitDir = current.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir.path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private func watchRepo(at path: String) {
        stopWatchingRepo()

        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            DispatchQueue.main.async { self.status = GitStatus(repoPath: path) }
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let service = Unmanaged<GitStatusService>.fromOpaque(info).takeUnretainedValue()
            service.scheduleRefresh()
        }

        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [gitDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        )

        guard let stream = stream else { return }
        FSEventStreamSetDispatchQueue(stream, gitQueue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func stopWatchingRepo() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        guard let path = currentRepoPath else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.refreshStatus(at: path)
        }
        refreshWorkItem = item
        gitQueue.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func refreshStatus(at path: String) {
        gitQueue.async { [weak self] in
            guard let self = self else { return }

            var result = GitStatus(repoPath: path)

            let isRepo = self.run("git rev-parse --is-inside-work-tree", at: path)
            guard isRepo == "true" else {
                DispatchQueue.main.async { self.status = result }
                return
            }
            result.isValidRepo = true

            let statusOutput = self.run("git status --porcelain=v1 -b", at: path)
            let lines = statusOutput.split(separator: "\n", omittingEmptySubsequences: true)

            if let firstLine = lines.first {
                let branchInfo = firstLine.dropFirst(min(3, firstLine.count))
                result.branch = branchInfo.split(separator: ".").first.map(String.init) ?? String(branchInfo)

                let (hasUpstream, ahead, behind) = parseAheadBehind(from: branchInfo)
                result.hasUpstream = hasUpstream
                result.aheadCount = ahead
                result.behindCount = behind
            }
            result.uncommittedChanges = max(0, lines.count - 1)

            let tag = self.run("git describe --tags --abbrev=0", at: path)
            result.lastTag = tag.isEmpty ? "no tags" : tag

            DispatchQueue.main.async { self.status = result }
        }
    }

    private func run(_ command: String, at path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func parseAheadBehind(from branchInfo: Substring) -> (hasUpstream: Bool, ahead: Int, behind: Int) {
        guard branchInfo.contains("...") else {
            return (false, 0, 0)
        }

        var ahead = 0
        var behind = 0

        if let bracketStart = branchInfo.firstIndex(of: "["),
           let bracketEnd = branchInfo.firstIndex(of: "]") {
            let content = branchInfo[branchInfo.index(after: bracketStart)..<bracketEnd]
            for part in content.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ahead") {
                    ahead = Int(trimmed.dropFirst("ahead ".count)) ?? 0
                } else if trimmed.hasPrefix("behind") {
                    behind = Int(trimmed.dropFirst("behind ".count)) ?? 0
                }
            }
        }

        return (true, ahead, behind)
    }

    func stagedDiff() -> String {
        guard let path = currentRepoPath else { return "" }
        return run("git diff --staged", at: path)
    }

    func stageAll() {
        guard let path = currentRepoPath else { return }
        _ = run("git add -A", at: path)
        scheduleRefresh()
    }

    func commit(message: String) {
        guard let path = currentRepoPath, !message.isEmpty else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")

        do {
            try message.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = run("git commit -F \"\(tempURL.path)\"", at: path)
    }
}
