import Darwin

/// What a script's processes are using right now.
package struct ProcSample: Sendable, Equatable {
    package var cpuPercent: Double
    package var memoryBytes: UInt64
    package var ports: [UInt16]
    package var processCount: Int

    package init(cpuPercent: Double, memoryBytes: UInt64, ports: [UInt16], processCount: Int) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.ports = ports
        self.processCount = processCount
    }
}

/// Every process's parent and group, as of one moment.
///
/// From sysctl rather than libproc's proc_listchildpids and proc_listpids,
/// which the App Sandbox refuses.
package struct ProcTable: Sendable {
    private var childrenByParent: [pid_t: [pid_t]] = [:]
    private var membersByGroup: [pid_t: [pid_t]] = [:]

    package static func current() -> ProcTable {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var table = ProcTable()
        // Processes start between sizing the buffer and filling it: leave
        // room, and try again if it still wasn't enough.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return table }
            let stride = MemoryLayout<kinfo_proc>.stride
            var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            size = list.count * stride
            if sysctl(&mib, 4, &list, &size, nil, 0) != 0 {
                if errno == ENOMEM { continue }
                return table
            }
            for entry in list.prefix(size / stride) {
                let pid = entry.kp_proc.p_pid
                guard pid > 0 else { continue }
                table.childrenByParent[entry.kp_eproc.e_ppid, default: []].append(pid)
                table.membersByGroup[entry.kp_eproc.e_pgid, default: []].append(pid)
            }
            return table
        }
        return table
    }

    package func children(of pid: pid_t) -> [pid_t] {
        childrenByParent[pid] ?? []
    }

    package func members(of group: pid_t) -> [pid_t] {
        membersByGroup[group] ?? []
    }
}

/// libproc lookups for one process or a tree of them.
package enum ProcTree {
    package static func exists(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    package static func groupMembers(_ group: pid_t) -> [pid_t] {
        ProcTable.current().members(of: group)
    }

    /// Everything under `root` (not `root` itself), plus whatever is still in
    /// `group`: a process whose parent quit has left the tree but not the group.
    package static func tree(root: pid_t, group: pid_t?, in table: ProcTable = .current()) -> [pid_t] {
        var queue = table.children(of: root)
        if let group, group > 0 { queue += table.members(of: group) }
        var seen = Set<pid_t>()
        var out: [pid_t] = []
        while let pid = queue.popLast() {
            guard pid != root, seen.insert(pid).inserted else { continue }
            out.append(pid)
            queue += table.children(of: pid)
        }
        return out
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// User plus system CPU time, in nanoseconds. (libproc reports Mach ticks,
    /// which on Apple silicon aren't nanoseconds.)
    package static func cpuNanoseconds(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user + info.pti_total_system
        return ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// Physical footprint: the number Activity Monitor calls Memory.
    package static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// Resident memory. Counts shared pages that the footprint leaves out, but
    /// the App Sandbox allows it where it refuses the footprint.
    package static func residentSize(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_resident_size
    }

    /// TCP ports the process is listening on. Always none in the App
    /// Sandbox, which doesn't let a process list another's files.
    package static func listeningPorts(_ pid: pid_t) -> [UInt16] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let used = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard used > 0 else { return [] }
        var ports = Set<UInt16>()
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            // Network byte order in the low 16 bits.
            ports.insert(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
        }
        return ports.sorted()
    }

    /// When the process started, in seconds since 1970. With the pid, it
    /// tells a process apart from a later one that got the same pid.
    package static func startTime(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    /// The name of the file the process was started from, up to 16
    /// characters. Unlike the path, it stays put when that file is deleted
    /// or moved, as when an update replaces the app under a running shim.
    package static func name(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Nil once the file the process was started from is gone.
    package static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Samples CPU, memory and ports for several process trees at a time. CPU
/// is a rate, so it compares with the previous sample; the first sample of a
/// process counts it as idle.
///
/// Keeps state between calls: use one from one queue.
package final class ProcSampler: @unchecked Sendable {
    package struct Root: Sendable {
        package var id: String
        package var pid: pid_t
        package var group: pid_t?

        package init(id: String, pid: pid_t, group: pid_t?) {
            self.id = id
            self.pid = pid
            self.group = group
        }
    }

    private var previous: [pid_t: (cpu: UInt64, at: UInt64)] = [:]

    package init() {}

    package func sample(_ roots: [Root], ports: Bool) -> [String: ProcSample] {
        var results: [String: ProcSample] = [:]
        var seen = Set<pid_t>()
        let table = ProcTable.current()
        for root in roots {
            let pids = ProcTree.tree(root: root.pid, group: root.group, in: table)
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            var cpu = 0.0
            var memory: UInt64 = 0
            var portSet = Set<UInt16>()
            for pid in pids {
                seen.insert(pid)
                if let total = ProcTree.cpuNanoseconds(pid) {
                    if let last = previous[pid], now > last.at, total >= last.cpu {
                        cpu += Double(total - last.cpu) / Double(now - last.at) * 100
                    }
                    previous[pid] = (total, now)
                }
                memory += ProcTree.footprint(pid) ?? ProcTree.residentSize(pid) ?? 0
                if ports { portSet.formUnion(ProcTree.listeningPorts(pid)) }
            }
            results[root.id] = ProcSample(
                cpuPercent: cpu, memoryBytes: memory, ports: portSet.sorted(), processCount: pids.count
            )
        }
        previous = previous.filter { seen.contains($0.key) }
        return results
    }
}
