import Foundation

/// Ping a pinned session once this little of its cache TTL remains. A tick can
/// land ~75s late and a ping takes ~10s, so the lead has to cover both.
func pingLead(ttl: TimeInterval) -> TimeInterval { ttl >= 3600 ? 10 * 60 : 2 * 60 }
/// A forgotten pin would otherwise keep paying cache reads all night.
let pinMaxAge: TimeInterval = 8 * 3600
/// Near the 5-hour limit, real turns matter more than keeping idle ones warm.
let keepWarmPauseAbovePct: Double = 90
/// A ping must read back at least this share of the session's last context.
/// Less means it hit a different prefix, and every later ping would be warming
/// that one at write prices instead of the session's.
let pingMinCacheRead = 0.9
let pingTimeout: TimeInterval = 120
let pingPrompt = "Keep-warm ping from Claude Usage. Do not use any tools. Reply with exactly: ok"

let configDir = NSHomeDirectory() + "/.config/claude-usage-bar"

struct Pin: Codable, Equatable {
    let sessionId: String
    let pinnedAt: Date
    /// When the last successful ping was sent. Pings are not persisted to the
    /// transcript, so this is the only record that the cache was refreshed.
    var lastPingAt: Date?
    /// Conductor stops idle chat processes, but the cache lives server-side and
    /// Conductor resumes with the same flags. So the launch is captured while the
    /// process is alive and pinging carries on from it after the process exits.
    var cwd: String?
    var label: String?
    var exe: String?
    /// Without argv[0].
    var args: [String]?
}

struct CacheState {
    let refreshedAt: Date
    let ttl: TimeInterval
    let hit: Double?

    func remaining(at now: Date) -> TimeInterval {
        refreshedAt.addingTimeInterval(ttl).timeIntervalSince(now)
    }
}

/// When the session's cache was last refreshed, by a real turn or by a ping.
/// A read refreshes an entry at the TTL it was written with, so the session's
/// TTL holds for pings too.
func cacheState(_ a: AgentSession, pin: Pin?) -> CacheState? {
    guard let at = a.lastRequestAt, let ttl = a.cacheTTL else { return nil }
    let refreshed = max(at, pin?.lastPingAt ?? .distantPast)
    return CacheState(refreshedAt: refreshed, ttl: ttl, hit: a.cacheHit)
}

/// Busy sessions refresh their own cache. A cold one is left alone: pinging it
/// would rewrite the whole context at write prices, which is exactly what
/// pinning exists to avoid, and the next real turn pays that anyway.
func pingDue(_ a: AgentSession, pin: Pin, now: Date) -> Bool {
    guard !a.isBusy, let c = cacheState(a, pin: pin) else { return false }
    let left = c.remaining(at: now)
    return left > 0 && left <= pingLead(ttl: c.ttl)
}

/// Pins for keep-warm, persisted so they survive a relaunch. Main thread only.
final class PinStore {
    private let path: String
    private(set) var pins: [String: Pin] = [:]

    init(path: String = configDir + "/pins.json") {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let list = try? Self.decoder.decode([Pin].self, from: data) {
            pins = Dictionary(list.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func isPinned(_ id: String) -> Bool { pins[id] != nil }

    func toggle(_ id: String, now: Date = Date()) {
        pins[id] = pins[id] == nil ? Pin(sessionId: id, pinnedAt: now) : nil
        save()
    }

    /// Records how a live session was launched, so it can be pinged after exit.
    func capture(_ a: AgentSession) {
        guard pins[a.sessionId] != nil, let launch = processLaunch(a.pid) else { return }
        let args = Array(launch.args.dropFirst())
        guard pins[a.sessionId]?.args != args || pins[a.sessionId]?.label != a.label else { return }
        pins[a.sessionId]?.cwd = a.cwd
        pins[a.sessionId]?.label = a.label
        pins[a.sessionId]?.exe = launch.exe
        pins[a.sessionId]?.args = args
        save()
    }

    func recordPing(_ id: String, at: Date) {
        guard pins[id] != nil else { return }
        pins[id]?.lastPingAt = at
        save()
    }

    func remove(_ id: String) {
        guard pins.removeValue(forKey: id) != nil else { return }
        save()
    }

    /// Drops pins that have outlived `pinMaxAge`.
    func prune(now: Date = Date()) {
        let kept = pins.filter { now.timeIntervalSince($0.value.pinnedAt) < pinMaxAge }
        guard kept.count != pins.count else { return }
        pins = kept
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let list = pins.values.sorted { $0.pinnedAt < $1.pinnedAt }
        if let data = try? Self.encoder.encode(list) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Launching a ping

/// The exact executable, argv and environment of a running process, read from
/// KERN_PROCARGS2. `ps` truncates and loses the quoting around paths with spaces.
func processLaunch(_ pid: pid_t) -> (exe: String, args: [String], env: [String: String])? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = MemoryLayout<Int32>.size
    func next() -> String? {
        guard i < size else { return nil }
        let start = i
        while i < size, buf[i] != 0 { i += 1 }
        let s = String(decoding: buf[start..<i], as: UTF8.self)
        i += 1
        return s
    }
    guard let exe = next() else { return nil }
    // The exec path is NUL-padded to alignment before argv starts.
    while i < size, buf[i] == 0 { i += 1 }

    var args: [String] = []
    while args.count < argc, let s = next() { args.append(s) }
    guard args.count == argc else { return nil }

    var env: [String: String] = [:]
    while let s = next(), !s.isEmpty {
        if let eq = s.firstIndex(of: "=") {
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
    }
    return (exe, args, env)
}

/// Flags that drive the live process's I/O, identity or permissions. Everything
/// else is kept, because model, thinking, effort, tools and setting sources all
/// shape the request prefix and any difference turns the ping into a cache miss.
private let droppedWithValue: Set<String> = [
    "--output-format", "--input-format", "--permission-prompt-tool", "--resume", "-r",
    "--session-id", "--permission-mode", "--max-turns",
]
private let droppedBare: Set<String> = [
    "--verbose", "--continue", "-c", "--fork-session", "-p", "--print",
    "--dangerously-skip-permissions", "--replay-user-messages", "--include-partial-messages",
    "--no-session-persistence", "--session-mirror",
]

/// argv for a ping, built from the live session's argv (without argv[0]).
/// Forked and unpersisted so nothing lands in the session's transcript; default
/// permissions so a tool call is denied rather than run; hooks off so a Stop hook
/// cannot push it into extra turns.
func pingArguments(from live: [String], sessionId: String) -> [String] {
    var kept: [String] = []
    var i = 0
    while i < live.count {
        let arg = live[i]
        let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
        if droppedWithValue.contains(name) {
            i += arg.contains("=") ? 1 : 2
        } else if droppedBare.contains(name) {
            i += 1
        } else {
            kept.append(arg)
            i += 1
        }
    }
    return kept + [
        "-p", pingPrompt,
        "--resume", sessionId, "--fork-session", "--no-session-persistence",
        "--output-format", "json", "--max-turns", "1",
        "--settings", #"{"disableAllHooks":true}"#,
        // A compacted session has no skill listing in its history, so resume
        // appends all of it (~13k tokens) at write prices on every ping. Skills
        // ride in messages, not the tool list, so the prefix still matches.
        "--disable-slash-commands",
    ]
}

/// Token counts only: `total_cost_usd` on a resumed session includes the cost
/// the session had already run up, restored from its transcript.
struct PingResult {
    let cacheRead: Int
    let cacheWrite: Int
    let input: Int
}

enum PingError: Error, CustomStringConvertible {
    case processGone
    case launch(String)
    case timeout
    case failed(String)

    var description: String {
        switch self {
        case .processGone: return "session exited before its launch was captured"
        case .launch(let e): return "could not launch claude: \(e)"
        case .timeout: return "ping timed out"
        case .failed(let e): return e
        }
    }
}

func parsePingOutput(_ data: Data) -> Result<PingResult, PingError> {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let text = String(decoding: data.prefix(200), as: UTF8.self)
        return .failure(.failed("unreadable output: \(text)"))
    }
    if root["is_error"] as? Bool == true {
        return .failure(.failed("claude error: \((root["result"] as? String)?.prefix(200) ?? "unknown")"))
    }
    guard let u = root["usage"] as? [String: Any] else { return .failure(.failed("no usage in output")) }
    return .success(PingResult(cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                               cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
                               input: u["input_tokens"] as? Int ?? 0))
}

/// The live process's launch when it is running, else the one captured at pin
/// time. The environment is borrowed from a live process of the same binary:
/// launched from Finder, ours lacks the PATH that MCP servers need to start.
func pingLaunch(_ a: AgentSession, pin: Pin?, live: [AgentSession]) -> (exe: String, args: [String], env: [String: String])? {
    if a.pid > 0, kill(a.pid, 0) == 0, let l = processLaunch(a.pid) {
        return (l.exe, Array(l.args.dropFirst()), l.env)
    }
    guard let exe = pin?.exe, let args = pin?.args else { return nil }
    let env = live.lazy.compactMap { processLaunch($0.pid) }.first { $0.exe == exe }?.env
    return (exe, args, env ?? ProcessInfo.processInfo.environment)
}

/// Blocks for up to `pingTimeout`; call off the main thread.
func runPing(_ a: AgentSession, pin: Pin?, live: [AgentSession]) -> Result<PingResult, PingError> {
    guard let launch = pingLaunch(a, pin: pin, live: live) else { return .failure(.processGone) }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch.exe)
    p.arguments = pingArguments(from: launch.args, sessionId: a.sessionId)
    p.environment = launch.env
    p.currentDirectoryURL = URL(fileURLWithPath: a.cwd)
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return .failure(.launch(error.localizedDescription)) }

    var timedOut = false
    let watchdog = DispatchWorkItem { timedOut = true; p.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + pingTimeout, execute: watchdog)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    watchdog.cancel()
    if timedOut { return .failure(.timeout) }
    return parsePingOutput(data)
}

/// One line per ping, so what keep-warm spends can be audited afterwards.
func logPing(_ label: String, sessionId: String, _ result: Result<PingResult, PingError>, at: Date) {
    let ts = ISO8601DateFormatter().string(from: at)
    let line: String
    switch result {
    case .success(let r):
        line = "\(ts) \(sessionId.prefix(8)) \(label): read \(r.cacheRead) write \(r.cacheWrite) in \(r.input)\n"
    case .failure(let e):
        line = "\(ts) \(sessionId.prefix(8)) \(label): FAILED \(e)\n"
    }
    appendLog(line, to: "keepwarm.log")
}

/// Appends to a log in the config directory.
func appendLog(_ line: String, to name: String) {
    let path = configDir + "/" + name
    try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
    }
}
