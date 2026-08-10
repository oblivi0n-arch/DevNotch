import Darwin
import Foundation

enum ProcessInspector {

    static func currentWorkingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)

        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }

        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
    }

    static func snapshotAllProcesses() -> [(pid: pid_t, ppid: pid_t, name: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid=,comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            return output.split(separator: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count >= 3,
                      let pid = pid_t(parts[0]),
                      let ppid = pid_t(parts[1]) else { return nil }
                return (pid, ppid, String(parts[2]))
            }
        } catch {
            return []
        }
    }
    
    static func findShellPID(startingAt rootPID: pid_t, in snapshot: [(pid: pid_t, ppid: pid_t, name: String)], maxDepth: Int = 4) -> pid_t? {
        let shellNames: Set<String> = ["zsh", "bash", "fish", "sh"]
        var queue: [(pid: pid_t, depth: Int)] = [(rootPID, 0)]
        var visited = Set<pid_t>()

        while !queue.isEmpty {
            let (pid, depth) = queue.removeFirst()
            guard !visited.contains(pid) else { continue }
            visited.insert(pid)

            if let entry = snapshot.first(where: { $0.pid == pid }),
               shellNames.contains(where: { entry.name.hasSuffix($0) }) {
                return pid
            }
            guard depth < maxDepth else { continue }
            for child in snapshot.filter({ $0.ppid == pid }) {
                queue.append((child.pid, depth + 1))
            }
        }
        return nil
    }
}
