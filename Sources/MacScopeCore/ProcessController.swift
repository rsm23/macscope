import Darwin
import Foundation

public enum ProcessController {
    public static func preflight(_ request: ProcessActionRequest) throws -> ActionPreflight {
        let current = try processIdentity(pid: request.pid)
        guard abs(current.startedAt.timeIntervalSince(request.expectedStartTime)) < 1 else {
            throw CollectorError.unavailable("PID \(request.pid) now belongs to a different process")
        }
        let operation: String
        let effect: String
        let reversible: Bool
        switch request.kind {
        case .terminate:
            operation = "SIGTERM"
            effect = "Ask \(current.name) to terminate gracefully"
            reversible = false
        case .kill:
            operation = "SIGKILL"
            effect = "Immediately terminate \(current.name); unsaved work may be lost"
            reversible = false
        case .stop:
            operation = "SIGSTOP"
            effect = "Suspend \(current.name)"
            reversible = true
        case .resume:
            operation = "SIGCONT"
            effect = "Resume \(current.name)"
            reversible = true
        case .renice:
            operation = "setpriority"
            effect = "Change \(current.name) priority to \(request.priority ?? 0)"
            reversible = true
        }
        return ActionPreflight(
            target: "\(current.name) (PID \(request.pid))",
            operation: operation,
            expectedEffect: effect,
            confirmationPhrase: "\(operation) \(request.pid)",
            reversible: reversible
        )
    }

    public static func execute(_ request: ProcessActionRequest) async throws -> ActionResult {
        try executeSynchronously(request)
    }

    public static func executeSynchronously(_ request: ProcessActionRequest) throws -> ActionResult {
        _ = try preflight(request)
        let result: Int32
        switch request.kind {
        case .terminate: result = Darwin.kill(request.pid, SIGTERM)
        case .kill: result = Darwin.kill(request.pid, SIGKILL)
        case .stop: result = Darwin.kill(request.pid, SIGSTOP)
        case .resume: result = Darwin.kill(request.pid, SIGCONT)
        case .renice:
            guard let priority = request.priority, (-20...20).contains(priority) else {
                throw CollectorError.malformed("Priority must be between -20 and 20")
            }
            result = setpriority(PRIO_PROCESS, UInt32(request.pid), priority)
        }
        guard result == 0 else {
            throw CollectorError.permissionDenied(String(cString: strerror(errno)))
        }
        return ActionResult(succeeded: true, message: "Action sent to PID \(request.pid)", timestamp: .now)
    }

    private static func processIdentity(pid: Int32) throws -> (name: String, startedAt: Date) {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else {
            throw CollectorError.unavailable("Process \(pid) no longer exists or cannot be inspected")
        }
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = length > 0 ? decodedCString(nameBuffer) : "PID \(pid)"
        return (name, Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)))
    }
}
