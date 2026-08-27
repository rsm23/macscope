import Darwin
import Foundation

public actor ProcessCollector: Collector {
    public let id = "processes"

    private struct PreviousUsage: Sendable {
        let nanoseconds: UInt64
        let sampledAt: ContinuousClock.Instant
    }

    private var previous: [Int32: PreviousUsage] = [:]
    private let clock = ContinuousClock()

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [MetricDescriptor(id: "process.cpu", name: "Process CPU", source: "libproc", scope: "process", unit: "%", provenance: "proc_pidinfo")]
    }

    public func sample() async throws -> [ProcessSnapshot] {
        let capacity = max(proc_listallpids(nil, 0), 1)
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes >= 0 else {
            throw CollectorError.unavailable("proc_listallpids failed")
        }

        let now = clock.now
        var currentUsage: [Int32: PreviousUsage] = [:]
        var snapshots: [ProcessSnapshot] = []
        snapshots.reserveCapacity(Int(bytes))

        for pid in pids.prefix(Int(bytes)) where pid > 0 {
            guard let snapshot = readProcess(pid: pid, at: now, currentUsage: &currentUsage) else { continue }
            snapshots.append(snapshot)
        }

        previous = currentUsage
        return snapshots.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func readProcess(
        pid: pid_t,
        at now: ContinuousClock.Instant,
        currentUsage: inout [Int32: PreviousUsage]
    ) -> ProcessSnapshot? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }

        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize

        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0 ? decodedCString(nameBuffer) : "PID \(pid)"

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? decodedCString(pathBuffer) : nil

        var rusage = rusage_info_v4()
        let hasRusage = withUnsafeMutablePointer(to: &rusage) { pointer in
            pointer.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound) == 0
            }
        }
        let cumulative = hasRusage ? rusage.ri_user_time &+ rusage.ri_system_time : (hasTask ? task.pti_total_user &+ task.pti_total_system : 0)
        currentUsage[pid] = PreviousUsage(nanoseconds: cumulative, sampledAt: now)
        let cpuPercent: Double
        if let old = previous[pid], cumulative >= old.nanoseconds {
            let elapsed = old.sampledAt.duration(to: now).seconds
            cpuPercent = elapsed > 0 ? Double(cumulative - old.nanoseconds) / 1_000_000_000 / elapsed * 100 : 0
        } else {
            cpuPercent = 0
        }

        let startSeconds = TimeInterval(bsd.pbi_start_tvsec)
        return ProcessSnapshot(
            pid: pid,
            parentPID: Int32(bsd.pbi_ppid),
            name: name,
            executablePath: path,
            userID: bsd.pbi_uid,
            state: processState(bsd.pbi_status),
            cpuPercent: max(cpuPercent, 0),
            residentMemory: hasTask ? task.pti_resident_size : 0,
            virtualMemory: hasTask ? task.pti_virtual_size : 0,
            threads: hasTask ? Int32(task.pti_threadnum) : 0,
            bytesRead: hasRusage ? rusage.ri_diskio_bytesread : 0,
            bytesWritten: hasRusage ? rusage.ri_diskio_byteswritten : 0,
            startedAt: startSeconds > 0 ? Date(timeIntervalSince1970: startSeconds) : nil,
            availability: hasTask ? .available : .restricted
        )
    }

    private func processState(_ value: UInt32) -> String {
        switch Int32(value) {
        case SRUN: "Running"
        case SSLEEP: "Sleeping"
        case SSTOP: "Stopped"
        case SZOMB: "Zombie"
        case SIDL: "Idle"
        default: "Unknown"
        }
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
