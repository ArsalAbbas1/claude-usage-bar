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
        guard a.pid > 0, let claude = byPid[a.pid], a.registered(by: claude.started) == true else { return nil }
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

extension AgentSession {
    /// Whether the process that started at `started` (µs) wrote this entry: a
    /// pid reused after a crash belongs to a process that started after the
    /// entry was written. Nil for an entry without `startedAt`.
    func registered(by started: Int64) -> Bool? {
        startedAt.map { Double(started) <= $0.timeIntervalSince1970 * 1_000_000 }
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

// MARK: - Caps

/// Choices offered in the menu, in GB.
let commandCapChoices = [2, 3, 4]
let sessionCapChoices = [4, 6, 8]
/// SIGKILL follows SIGTERM after this long, for a command that ignores it.
let stopGrace: TimeInterval = 10
/// At critical, a command smaller than this frees too little to help, and the
/// pressure is then usually another app's.
let criticalStopMinBytes: UInt64 = 1 << 30
/// At most one critical notification or stop per this long. It is not reset
/// when pressure drops, so pressure hovering at the threshold cannot repeat them.
let criticalCooldown: TimeInterval = 15 * 60
/// Caps outside this range are ignored: 0 would stop every command, and a
/// value too large to count in bytes would crash the app.
let capRangeGB = 0.5...512.0

func validCap(_ gb: Double?) -> Double? { gb.flatMap { capRangeGB.contains($0) ? $0 : nil } }

/// Opt-in limits, all off by default. A nil cap is off.
struct MemoryCaps: Equatable {
    var commandGB: Double?
    var sessionGB: Double?
    var stopAtCritical = false

    var summary: String {
        "command cap \(commandGB.map(formatGB) ?? "off") · session cap \(sessionGB.map(formatGB) ?? "off")"
            + " · at critical: \(stopAtCritical ? "notify and stop the largest command" : "notify")"
    }
}

func formatGB(_ gb: Double) -> String {
    gb == gb.rounded() ? "\(Int(gb)) GB" : String(format: "%g GB", gb)
}

let configPath = configDir + "/config.json"

/// Caps live under "memory" in config.json. Other settings are planned for the
/// same file (#11), so saving keeps whatever else is in it.
func loadMemoryCaps(path: String = configPath) -> MemoryCaps {
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let m = root["memory"] as? [String: Any] else { return MemoryCaps() }
    return MemoryCaps(commandGB: validCap(m["commandCapGB"] as? Double),
                      sessionGB: validCap(m["sessionCapGB"] as? Double),
                      stopAtCritical: m["atCritical"] as? String == "stop")
}

/// False when nothing was saved. A config.json that does not parse is left as
/// it is, since rewriting it would drop every other setting in it.
@discardableResult
func saveMemoryCaps(_ caps: MemoryCaps, path: String = configPath) -> Bool {
    var root: [String: Any] = [:]
    if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        root = parsed
    }
    var m: [String: Any] = ["atCritical": caps.stopAtCritical ? "stop" : "notify"]
    m["commandCapGB"] = caps.commandGB
    m["sessionCapGB"] = caps.sessionGB
    root["memory"] = m
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
          (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { return false }
    return true
}

enum StopReason: Equatable, CustomStringConvertible {
    case commandCap(Double)
    case sessionCap(Double)
    case critical

    var description: String {
        switch self {
        case .commandCap(let gb): return "over the \(formatGB(gb)) command cap"
        case .sessionCap(let gb): return "its session's commands passed the \(formatGB(gb)) session cap"
        case .critical: return "memory pressure is critical"
        }
    }
}

enum MemoryAction: Equatable {
    case stop(MemoryCommand, session: String, reason: StopReason)
    /// Critical pressure, when stopping is not chosen, a command was stopped in
    /// the last 20 seconds, or nothing is worth stopping.
    case warnCritical
}

/// What the caps call for in one sample. `stopping` holds the roots of
/// commands already being stopped, so they are neither stopped twice nor
/// counted toward their session's cap while they exit. `lastStop` is when any
/// command was last stopped.
func memoryActions(_ m: MemorySnapshot, caps: MemoryCaps, stopping: Set<pid_t>, lastStop: Date?,
                   lastCritical: Date?, now: Date) -> [MemoryAction] {
    var actions: [MemoryAction] = []
    var taken = stopping
    func stop(_ c: MemoryCommand, in s: SessionMemory, _ why: StopReason) {
        guard taken.insert(c.root.pid).inserted else { return }
        actions.append(.stop(c, session: s.label, reason: why))
    }
    for s in m.sessions {
        if let cap = caps.commandGB {
            for c in s.commands where c.bytes > bytes(gb: cap) { stop(c, in: s, .commandCap(cap)) }
        }
        // The claude process is never stopped, so it does not count toward
        // the session cap either: stopping commands could not bring it down.
        let left = s.commands.filter { !taken.contains($0.root.pid) }
        if let cap = caps.sessionGB, let largest = left.first, left.reduce(0, { $0 + $1.bytes }) > bytes(gb: cap) {
            stop(largest, in: s, .sessionCap(cap))
        }
    }
    guard m.pressure == .critical,
          lastCritical.map({ now.timeIntervalSince($0) >= criticalCooldown }) ?? true else { return actions }
    let largest = m.sessions.flatMap { s in s.commands.map { (session: s, command: $0) } }
        .filter { !taken.contains($0.command.root.pid) }
        .max { $0.command.bytes < $1.command.bytes }
    // A stop in this sample, or one whose SIGKILL may not have landed and been
    // sampled yet, is already freeing memory; another stop now could be one too many.
    let settling = !actions.isEmpty || lastStop.map { now.timeIntervalSince($0) < stopGrace + memorySampleInterval } == true
    if caps.stopAtCritical, !settling, let pick = largest, pick.command.bytes >= criticalStopMinBytes {
        stop(pick.command, in: pick.session, .critical)
    } else {
        actions.append(.warnCritical)
    }
    return actions
}

func bytes(gb: Double) -> UInt64 { UInt64(gb * Double(1 << 30)) }

/// A pid's current start time and group, or nil once it is gone.
func liveProcess(_ pid: pid_t) -> (started: Int64, pgid: pid_t, zombie: Bool)? {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
    return (startTime(kp), kp.kp_eproc.e_pgid, Int32(kp.kp_proc.p_stat) == SZOMB)
}

/// Sends `sig` to a command and returns how many targets it reached. When the
/// root leads its own process group, as a Bash tool call's shell does, the
/// whole group gets it, which reaches processes forked since the sample. A pgid
/// is not reused while its group has members, so after the root exits the
/// group can only hold its leftovers. A session started inside the command
/// shares its group, so a group holding a `protected` pid is not signalled as a
/// group. Every sampled process that is still the same process is also
/// signalled on its own. Never pid 1, this app, or a `protected` pid.
func deliver(_ sig: Int32, to c: MemoryCommand, protected: Set<pid_t>) -> Int {
    func allowed(_ pid: pid_t) -> Bool { pid > 1 && pid != getpid() && !protected.contains(pid) }
    var reached = 0
    let root = c.root
    if root.pgid == root.pid, root.pid != getpgrp(), allowed(root.pid),
       let members = kinfoProcs([CTL_KERN, KERN_PROC, KERN_PROC_PGRP, root.pid]),
       members.allSatisfy({ allowed($0.kp_proc.p_pid) }) {
        let now = liveProcess(root.pid)
        if now == nil || (now?.started == root.started && now?.pgid == root.pid), killpg(root.pid, sig) == 0 {
            reached += 1
        }
    }
    for p in c.procs where allowed(p.pid) {
        guard let now = liveProcess(p.pid), now.started == p.started, !now.zombie else { continue }
        if kill(p.pid, sig) == 0 { reached += 1 }
    }
    return reached
}

/// Every session's claude process, read fresh from the registry each time a
/// command is signalled, since a session can start inside the command. Only an
/// entry proven stale is left out, so a reused pid inside a command can still
/// be stopped; one without `startedAt` stays protected.
func sessionPids(_ sessions: [AgentSession] = readAgentSessions()) -> Set<pid_t> {
    Set(sessions.filter { a in liveProcess(a.pid).flatMap { a.registered(by: $0.started) } != false }.map(\.pid))
}

/// Every stop, critical alert and change of cap, so what was stopped and why
/// can be checked afterwards.
func logMemory(_ text: String, at: Date = Date()) {
    appendLog("\(ISO8601DateFormatter().string(from: at)) \(text)\n", to: "memory.log")
}
