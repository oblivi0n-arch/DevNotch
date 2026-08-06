import Foundation
import AppKit
import Combine

struct BuildStatus: Equatable {
    var isBuilding: Bool = false
    var startedAt: Date? = nil
}

struct BuildResourceSample: Equatable, Identifiable {
    let id = UUID()
    var totalCPUPercent: Double = 0
    var totalMemoryMB: Double = 0
    var timestamp: Date = Date()
    var phase: BuildPhase = .compiling
}

enum BuildPhase: Equatable {
    case compiling
    case postCompile
}

final class BuildMonitorService: ObservableObject {
    @Published private(set) var status = BuildStatus()
    @Published private(set) var resourceHistory: [BuildResourceSample] = []

    private let xcodeBundleID = "com.apple.dt.Xcode"
    private let buildProcessSuffix = "SWBBuildService"

    private let pollQueue = DispatchQueue(label: "devnotch.buildmonitor", qos: .utility)
    private var pollTimer: Timer?
    private var didStart = false
    private var trackedRunPID: pid_t?
    private var buildFinishedWithoutRunAt: Date?
    private let runDetectionGracePeriod: TimeInterval = 5
    private var lastChildSeenAt: Date?

    private let appModeService: AppModeService
    private var modeCancellable: AnyCancellable?

    init(appModeService: AppModeService) {               
        self.appModeService = appModeService
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        modeCancellable = appModeService.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.handleModeChange(mode)
            }

        handleModeChange(appModeService.mode)
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func handleModeChange(_ mode: AppMode) {
        if case .dev(.xcode) = mode {
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        if status.isBuilding {
            status = BuildStatus(isBuilding: false, startedAt: nil)
        }
        trackedRunPID = nil
        buildFinishedWithoutRunAt = nil
        lastChildSeenAt = nil
    }

    private func poll() {
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            let resourceSnapshot = ProcessInspector.snapshotAllProcessesWithResources()
            let plainSnapshot = resourceSnapshot.map { (pid: $0.pid, ppid: $0.ppid, name: $0.name) }

            var compilingNow = false
            var sample: BuildResourceSample?

            if let buildServicePID = self.findBuildServicePID(in: plainSnapshot) {
                let subtree = self.collectSubtreePIDs(root: buildServicePID, in: plainSnapshot)
                
                let relevant = resourceSnapshot.filter { subtree.contains($0.pid) }
                let totalCPU = relevant.reduce(0.0) { $0 + $1.cpuPercent }
                let totalMemoryMB = Double(relevant.reduce(0) { $0 + $1.residentMemoryKB }) / 1024.0

                let hasExtraChildren = subtree.count > 1
                if hasExtraChildren {
                    lastChildSeenAt = Date()
                }

                let recentlySawChild = lastChildSeenAt.map { Date().timeIntervalSince($0) < 2.0 } ?? false
                let rootCPU = resourceSnapshot.first(where: { $0.pid == buildServicePID })?.cpuPercent ?? 0
                compilingNow = recentlySawChild && rootCPU > 3.0

                sample = BuildResourceSample(
                    totalCPUPercent: totalCPU,
                    totalMemoryMB: totalMemoryMB,
                    timestamp: Date(),
                    phase: compilingNow ? .compiling : .postCompile
                )
            }

            DispatchQueue.main.async {
                self.handlePollResult(compilingNow: compilingNow, sample: sample, snapshot: plainSnapshot)
            }
        }
    }

    private func handlePollResult(compilingNow: Bool, sample: BuildResourceSample?, snapshot: [(pid: pid_t, ppid: pid_t, name: String)]) {
        if compilingNow && !status.isBuilding {
            status = BuildStatus(isBuilding: true, startedAt: Date())
            resourceHistory = []
            trackedRunPID = nil
            buildFinishedWithoutRunAt = nil
        }
        guard status.isBuilding else { return }

        if let sample = sample {
            resourceHistory.append(sample)
        }

        if compilingNow {
            buildFinishedWithoutRunAt = nil
            return
        }

        if let runPID = trackedRunPID {
            if !snapshot.contains(where: { $0.pid == runPID }) {
                status = BuildStatus(isBuilding: false, startedAt: nil)
                trackedRunPID = nil
            }
            return
        }

        if let launchedPID = findFreshlyLaunchedAppPID(in: snapshot) {
            trackedRunPID = launchedPID
            buildFinishedWithoutRunAt = nil
            return
        }

        if buildFinishedWithoutRunAt == nil {
            buildFinishedWithoutRunAt = Date()
        } else if Date().timeIntervalSince(buildFinishedWithoutRunAt!) > runDetectionGracePeriod {
            status = BuildStatus(isBuilding: false, startedAt: nil)
            trackedRunPID = nil
            buildFinishedWithoutRunAt = nil
        }
    }

    private func findFreshlyLaunchedAppPID(in snapshot: [(pid: pid_t, ppid: pid_t, name: String)]) -> pid_t? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return snapshot.first {
            $0.pid != ownPID &&
            $0.name.contains("/DerivedData/") &&
            $0.name.contains("/Build/Products/")
        }?.pid
    }

    private func findBuildServicePID(in snapshot: [(pid: pid_t, ppid: pid_t, name: String)]) -> pid_t? {
        let xcodePIDs = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == xcodeBundleID }
            .map { $0.processIdentifier }

        for rootPID in xcodePIDs {
            if let found = findDescendant(suffix: buildProcessSuffix, from: rootPID, in: snapshot) {
                return found
            }
        }
        return nil
    }

    private func findDescendant(suffix: String, from rootPID: pid_t, in snapshot: [(pid: pid_t, ppid: pid_t, name: String)], maxDepth: Int = 4) -> pid_t? {
        var queue: [(pid: pid_t, depth: Int)] = [(rootPID, 0)]
        var visited = Set<pid_t>()

        while !queue.isEmpty {
            let (pid, depth) = queue.removeFirst()
            guard !visited.contains(pid) else { continue }
            visited.insert(pid)

            if let entry = snapshot.first(where: { $0.pid == pid }), entry.name.hasSuffix(suffix) {
                return pid
            }
            guard depth < maxDepth else { continue }
            for child in snapshot.filter({ $0.ppid == pid }) {
                queue.append((child.pid, depth + 1))
            }
        }
        return nil
    }

    private func collectSubtreePIDs(root: pid_t, in snapshot: [(pid: pid_t, ppid: pid_t, name: String)]) -> Set<pid_t> {
        var result: Set<pid_t> = [root]
        var queue: [pid_t] = [root]

        while !queue.isEmpty {
            let pid = queue.removeFirst()
            for child in snapshot.filter({ $0.ppid == pid }) {
                if !result.contains(child.pid) {
                    result.insert(child.pid)
                    queue.append(child.pid)
                }
            }
        }
        return result
    }
}
