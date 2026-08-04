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

    static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func childPIDs(of pid: pid_t) -> [pid_t] {
        let bufferSize = proc_listchildpids(pid, nil, 0)
        guard bufferSize > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.size)
        let actualSize = proc_listchildpids(pid, &pids, bufferSize)
        guard actualSize > 0 else { return [] }

        let count = Int(actualSize) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count))
    }

    static func findShellPID(startingAt rootPID: pid_t, maxDepth: Int = 4) -> pid_t? {
        let shellNames: Set<String> = ["zsh", "bash", "fish", "sh"]
        var queue: [(pid: pid_t, depth: Int)] = [(rootPID, 0)]
        var found: pid_t?

        while !queue.isEmpty {
            let (pid, depth) = queue.removeFirst()

            if let name = processName(of: pid), shellNames.contains(name) {
                found = pid
            }
            guard depth < maxDepth else { continue }
            for child in childPIDs(of: pid) {
                queue.append((child, depth + 1))
            }
        }
        return found
    }
}
