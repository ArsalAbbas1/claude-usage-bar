import Foundation

/// Memory moves faster than usage: a runaway test loop can fill swap in a minute.
let memorySampleInterval: TimeInterval = 10
/// A session row shows its memory from 1 GB (orange) and turns red from 4 GB.
/// A claude process alone holds a few hundred MB, so below 1 GB says nothing.
let memoryWarnBytes: UInt64 = 1 << 30
let memoryAlertBytes: UInt64 = 4 << 30

/// The kernel's own verdict, the one Activity Monitor graphs. Free memory
/// misleads: it read 48% at warning while the compressor held 6 GB.
enum MemoryPressure {
    case normal, warning, critical

    static func current() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return level >= 4 ? .critical : level >= 2 ? .warning : .normal
    }
}

/// One process as sampled. Pids are reused, so the start time is what pins it.
struct Proc: Equatable {
    let pid: pid_t
    let ppid: pid_t
    let pgid: pid_t
    let name: String
    /// Microseconds since 1970.
    let started: Int64
    var path = ""
    /// Physical footprint: Activity Monitor's "Memory" column.
    var bytes: UInt64 = 0
}

/// What a session started: one child of its claude process (a Bash tool call,
/// a background task, an MCP server) and everything under that child.
struct MemoryCommand: Equatable {
    /// Root first.
    let procs: [Proc]

    var root: Proc { procs[0] }
    var bytes: UInt64 { procs.reduce(0) { $0 + $1.bytes } }
    /// Named after its largest process; the root is usually just a shell.
    var name: String { procs.max { $0.bytes < $1.bytes }?.name ?? root.name }
}

struct SessionMemory: Equatable {
    /// The session's claude process.
    let pid: pid_t
    let label: String
    /// The claude process alone.
    let ownBytes: UInt64
    /// Largest first.
    let commands: [MemoryCommand]

    var bytes: UInt64 { commands.reduce(ownBytes) { $0 + $1.bytes } }
}

struct MemorySnapshot {
    let pressure: MemoryPressure
    let swapBytes: UInt64
    let sessions: [SessionMemory]
    /// Largest first: every session's processes as "Claude Code", the rest by app.
    let apps: [(name: String, bytes: UInt64)]

    var claudeBytes: UInt64 { sessions.reduce(0) { $0 + $1.bytes } }

    func session(_ pid: pid_t) -> SessionMemory? { sessions.first { $0.pid == pid } }
}

/// Reads every process this user owns, so it stays off the main thread. Nil
/// when the process table cannot be read.
func takeMemorySnapshot(sessions: [AgentSession]) -> MemorySnapshot? {
    guard let procs = readProcesses() else { return nil }
    let mine = sessionMemory(procs, sessions: sessions)
    return MemorySnapshot(pressure: .current(), swapBytes: swapUsed(), sessions: mine,
                          apps: largestApps(procs, sessions: mine))
}

/// The processes a KERN_PROC query matches. Processes started between sizing
/// the table and reading it overflow it, which is likeliest while something is
/// forking fast, so an overflow is retried with more room.
func kinfoProcs(_ query: [Int32]) -> [kinfo_proc]? {
    var mib = query
    let stride = MemoryLayout<kinfo_proc>.stride
    for slack in [32, 512, 4096] {
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + slack)
        size = table.count * stride
        if sysctl(&mib, u_int(mib.count), &table, &size, nil, 0) == 0 { return Array(table.prefix(size / stride)) }
        guard errno == ENOMEM else { return nil }
    }
    return nil
}

/// This user's processes, with their footprint and executable path. Other
/// users' processes cannot be measured without root.
func readProcesses() -> [Proc]? {
    guard let table = kinfoProcs([CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]) else { return nil }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return table.map { kp in
        let pid = kp.kp_proc.p_pid
        let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let n = Int(proc_pidpath(pid, &path, UInt32(path.count)))
        return Proc(pid: pid, ppid: kp.kp_eproc.e_ppid, pgid: kp.kp_eproc.e_pgid, name: name,
                    started: startTime(kp),
                    path: n > 0 ? String(decoding: path.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "",
                    bytes: footprint(pid) ?? 0)
    }
}

func startTime(_ kp: kinfo_proc) -> Int64 {
    let t = kp.kp_proc.p_un.__p_starttime
    return Int64(t.tv_sec) * 1_000_000 + Int64(t.tv_usec)
}

func footprint(_ pid: pid_t) -> UInt64? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return rc == 0 ? info.ri_phys_footprint : nil
}

func swapUsed() -> UInt64 {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : 0
}

/// Each live session's claude process and the commands under it. A session
/// started from inside another one is counted once, as itself. A registry entry
/// outlives a crash and its pid is soon reused, so a session counts only if its
/// process started before the entry was written.
func sessionMemory(_ procs: [Proc], sessions: [AgentSession]) -> [SessionMemory] {
    let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    let verified = sessions.compactMap { a -> (session: AgentSession, claude: Proc)? in
        guard a.pid > 0, let claude = byPid[a.pid], let at = a.startedAt,
              Double(claude.started) <= at.timeIntervalSince1970 * 1_000_000 else { return nil }
        return (a, claude)
    }
    let sessionPids = Set(verified.map(\.claude.pid))
    let children = Dictionary(grouping: procs.filter { $0.pid != $0.ppid && !sessionPids.contains($0.pid) },
                              by: \.ppid)
    func tree(_ root: Proc) -> [Proc] {
        var out: [Proc] = [], stack = [root], seen = Set<pid_t>()
        while let p = stack.popLast() {
            guard seen.insert(p.pid).inserted else { continue }
            out.append(p)
            stack += children[p.pid] ?? []
        }
        return out
    }
    return verified.map { a, claude in
        let commands = (children[a.pid] ?? []).map { MemoryCommand(procs: tree($0)) }
        return SessionMemory(pid: a.pid, label: a.label, ownBytes: claude.bytes,
                             commands: commands.sorted { $0.bytes > $1.bytes })
    }
}

/// Memory per app, largest first, so the menu can say when it is not Claude.
func largestApps(_ procs: [Proc], sessions: [SessionMemory], limit: Int = 5) -> [(name: String, bytes: UInt64)] {
    var inSession = Set(sessions.map(\.pid))
    for s in sessions { for c in s.commands { inSession.formUnion(c.procs.map(\.pid)) } }
    var sums: [String: UInt64] = [:]
    let claude = sessions.reduce(0) { $0 + $1.bytes }
    if claude > 0 { sums["Claude Code"] = claude }
    for p in procs where !inSession.contains(p.pid) { sums[appName(p), default: 0] += p.bytes }
    return sums.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
}

/// The outermost bundle in the path, so Chrome's helpers count as Chrome.
/// "/Contents/" is required because some support folders are named like
/// bundles ("com.conductor.app"). Web views, Safari's and other apps', run in
/// shared WebKit processes that no path ties to an app.
func appName(_ p: Proc) -> String {
    if let r = p.path.range(of: ".app/Contents/") {
        let bundle = p.path[..<r.lowerBound]
        return String(bundle[(bundle.lastIndex(of: "/").map(bundle.index(after:)) ?? bundle.startIndex)...])
    }
    if p.path.contains("/WebKit.framework/") { return "WebKit" }
    return p.path.isEmpty ? p.name : (p.path as NSString).lastPathComponent
}

/// "1.4 GB" from 1 GB, "512 MB" below, in Activity Monitor's 1024-based units.
func formatBytes(_ b: UInt64) -> String {
    let gb = Double(b) / Double(1 << 30)
    return gb >= 1 ? String(format: "%.1f GB", gb) : "\(b >> 20) MB"
}

/// Menu bar prefix while memory is under pressure. Shared by the GUI and
/// --dump, like the agent badges.
func memoryBadge(_ p: MemoryPressure) -> String? {
    p == .normal ? nil : "mem"
}
