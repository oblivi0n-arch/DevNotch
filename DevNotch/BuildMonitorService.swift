import Foundation
import AppKit
import Combine

struct BuildStatus: Equatable {
    var isBuilding: Bool = false
    var startedAt: Date? = nil
}

final class BuildMonitorService: ObservableObject {
    @Published private(set) var status = BuildStatus()

    private let xcodeBundleID = "com.apple.dt.Xcode"
    private let buildProcessSuffix = "SWBBuildService"

    private let pollQueue = DispatchQueue(label: "devnotch.buildmonitor", qos: .utility)
    private var pollTimer: Timer?
    private var didStart = false

    init() {}

    func start() {
        guard !didStart else { return }
        didStart = true

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func poll() {
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            let snapshot = ProcessInspector.snapshotAllProcesses()
            let buildingNow = self.isBuildServiceRunning(in: snapshot)

            DispatchQueue.main.async {
                if buildingNow && !self.status.isBuilding {
                    self.status = BuildStatus(isBuilding: true, startedAt: Date())
                } else if !buildingNow && self.status.isBuilding {
                    self.status = BuildStatus(isBuilding: false, startedAt: nil)
                }
            }
        }
    }

    private func isBuildServiceRunning(in snapshot: [(pid: pid_t, ppid: pid_t, name: String)]) -> Bool {
        let xcodePIDs = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == xcodeBundleID }
            .map { $0.processIdentifier }

        for rootPID in xcodePIDs {
            if hasDescendant(suffix: buildProcessSuffix, from: rootPID, in: snapshot) {
                return true
            }
        }
        return false
    }

    private func hasDescendant(suffix: String, from rootPID: pid_t, in snapshot: [(pid: pid_t, ppid: pid_t, name: String)], maxDepth: Int = 4) -> Bool {
        var queue: [(pid: pid_t, depth: Int)] = [(rootPID, 0)]
        var visited = Set<pid_t>()

        while !queue.isEmpty {
            let (pid, depth) = queue.removeFirst()
            guard !visited.contains(pid) else { continue }
            visited.insert(pid)

            if let entry = snapshot.first(where: { $0.pid == pid }), entry.name.hasSuffix(suffix) {
                return true
            }
            guard depth < maxDepth else { continue }
            for child in snapshot.filter({ $0.ppid == pid }) {
                queue.append((child.pid, depth + 1))
            }
        }
        return false
    }
}
