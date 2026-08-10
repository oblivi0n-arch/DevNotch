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

enum GitCommitError: LocalizedError {
    case noRepo
    case emptyMessage
    case writeFailed
    case commitFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRepo:
            return "No active git repository"
        case .emptyMessage:
            return "Commit message is empty"
        case .writeFailed:
            return "Could not write the commit message to a temp file"
        case .commitFailed(let details):
            return details.isEmpty ? "git commit failed" : details
        }
    }
}

enum GitTagError: LocalizedError {
    case noRepo
    case emptyName
    case invalidName(String)
    case tagExists(String)
    case writeFailed
    case tagFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRepo:
            return "No active git repository"
        case .emptyName:
            return "Tag name is empty"
        case .invalidName(let name):
            return "\"\(name)\" is not a valid semantic version tag"
        case .tagExists(let name):
            return "Tag \"\(name)\" already exists"
        case .writeFailed:
            return "Could not write the tag message to a temp file"
        case .tagFailed(let details):
            return details.isEmpty ? "git tag failed" : details
        }
    }
}

final class GitStatusService: ObservableObject {
    static func isValidTagName(_ name: String) -> Bool {
        let pattern = #"^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }
    @Published private(set) var status = GitStatus()

    private let appModeService: AppModeService
    private var modeCancellable: AnyCancellable?

    private var currentRepoPath: String?
    private var eventStream: FSEventStreamRef?
    private var refreshWorkItem: DispatchWorkItem?
    private let gitQueue = DispatchQueue(label: "devnotch.git", qos: .utility)

    private var didStart = false

    init(appModeService: AppModeService) {
        self.appModeService = appModeService
    }
    
    func checkForActiveRepo() {
        recomputeActiveRepo()
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        modeCancellable = appModeService.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeActiveRepo()
            }

        DispatchQueue.main.async { [weak self] in
            self?.recomputeActiveRepo()
        }
    }

    deinit {
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

            let isRepo = self.git(["rev-parse", "--is-inside-work-tree"], at: path)
            guard isRepo == "true" else {
                DispatchQueue.main.async { self.status = result }
                return
            }
            result.isValidRepo = true

            let statusOutput = self.git(["status", "--porcelain=v1", "-b"], at: path)
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

            let tag = self.git(["describe", "--tags", "--abbrev=0"], at: path)
            result.lastTag = tag.isEmpty ? "no tags" : tag

            DispatchQueue.main.async { self.status = result }
        }
    }

    private static let gitExecutableURL: URL = {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        let path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
        return URL(fileURLWithPath: path)
    }()

    private func git(_ arguments: [String], at path: String) -> String {
        let process = Process()
        process.executableURL = Self.gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func gitResult(_ arguments: [String], at path: String) -> (output: String, errorOutput: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = Self.gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()

            var errData = Data()
            let errQueue = DispatchQueue(label: "devnotch.git.stderr")
            errQueue.async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            }

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            errQueue.sync { }

            process.waitUntilExit()

            let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (output, errorOutput, process.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
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
    
    // MARK: - Queue bridging

    private func onGitQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            gitQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func onGitQueueThrowing<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            gitQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stagedDiff() async -> String {
        await onGitQueue {
            guard let path = self.currentRepoPath else { return "" }
            return self.git(["diff", "--staged"], at: path)
        }
    }

    func stageAll() async {
        await onGitQueue {
            guard let path = self.currentRepoPath else { return }
            _ = self.git(["add", "-A"], at: path)
            self.scheduleRefresh()
        }
    }

    func commitsSinceLastTag() async -> (lastTag: String?, log: String) {
        await onGitQueue {
            guard let path = self.currentRepoPath else { return (nil, "") }

            let tag = self.git(["describe", "--tags", "--abbrev=0"], at: path)

            var logArguments = ["log", "--pretty=format:%s"]
            if !tag.isEmpty {
                logArguments.append("\(tag)..HEAD")
            }
            let log = self.git(logArguments, at: path)

            return (tag.isEmpty ? nil : tag, log)
        }
    }

    @discardableResult
    func commit(message: String) async throws -> String {
        try await onGitQueueThrowing {
            guard let path = self.currentRepoPath else {
                throw GitCommitError.noRepo
            }
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GitCommitError.emptyMessage
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".txt")

            do {
                try message.write(to: tempURL, atomically: true, encoding: .utf8)
            } catch {
                throw GitCommitError.writeFailed
            }
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let result = self.gitResult(["commit", "-F", tempURL.path], at: path)
            guard result.exitCode == 0 else {
                throw GitCommitError.commitFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
            }

            self.scheduleRefresh()
            return result.output
        }
    }

    func createAnnotatedTag(name: String, message: String) async throws {
        try await onGitQueueThrowing {
            guard let path = self.currentRepoPath else {
                throw GitTagError.noRepo
            }

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw GitTagError.emptyName
            }
            guard GitStatusService.isValidTagName(trimmedName) else {
                throw GitTagError.invalidName(trimmedName)
            }

            let existing = self.git(["tag", "-l", trimmedName], at: path)
            guard existing.isEmpty else {
                throw GitTagError.tagExists(trimmedName)
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".txt")

            do {
                try message.write(to: tempURL, atomically: true, encoding: .utf8)
            } catch {
                throw GitTagError.writeFailed
            }
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let result = self.gitResult(["tag", "-a", trimmedName, "-F", tempURL.path], at: path)
            guard result.exitCode == 0 else {
                throw GitTagError.tagFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
            }

            self.scheduleRefresh()
        }
    }
}
