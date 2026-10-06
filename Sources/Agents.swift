import Foundation

/// Size badge thresholds. Auto-compact only fires near the full window, so a
/// session can sit at several hundred k for hours; this is the cue to steer it.
let contextWarnTokens = 200_000
let contextAlertTokens = 500_000
/// A busy session whose transcripts have not been written for this long is
/// flagged: usually a hung tool or MCP call, sometimes just a long command.
let silentAfter: TimeInterval = 10 * 60
/// Waiting this long earns a notification; shorter waits are usually answered.
let waitingNotifyAfter: TimeInterval = 60

struct AgentSession {
    let pid: pid_t
    let name: String
    let cwd: String
    let status: String        // busy | idle | waiting
    let sessionId: String
    /// When `status` last changed, per Claude Code's registry.
    let statusSince: Date?
    /// What a waiting session is blocked on, e.g. "dialog open".
    let waitingFor: String?
    /// When the process registered, a second or so after it started.
    var startedAt: Date?
    var subagents: Int = 0
    var contextTokens: Int?
    var cacheHit: Double?
    var lastRequestAt: Date?
    var cacheTTL: TimeInterval?
    /// Newest write to the session's transcript or any of its subagents'.
    var lastWriteAt: Date?
    /// Conductor chat title if there is one, else branch, else the derived name.
    var label: String = ""
    var fromConductor = false

    var isBusy: Bool { status == "busy" }
    var isWaiting: Bool { status == "waiting" }

    /// How long a busy session has gone without writing anything, once that
    /// passes `silentAfter`.
    func silence(at now: Date = Date()) -> TimeInterval? {
        guard isBusy, let last = lastWriteAt else { return nil }
        let quiet = now.timeIntervalSince(last)
        return quiet >= silentAfter ? quiet : nil
    }
}

struct AgentSnapshot {
    let sessions: [AgentSession]

    /// Longest-waiting first: that is the one costing the most time.
    var waiting: [AgentSession] {
        sessions.filter(\.isWaiting)
            .sorted { ($0.statusSince ?? .distantFuture) < ($1.statusSince ?? .distantFuture) }
    }
    var busy: [AgentSession] { sessions.filter(\.isBusy) }
    var idle: [AgentSession] { sessions.filter { !$0.isBusy && !$0.isWaiting } }
    var busyCount: Int { busy.count }
    var subagentCount: Int { sessions.reduce(0) { $0 + $1.subagents } }
    var anyRunning: Bool { busyCount > 0 || subagentCount > 0 }
}

/// Claude Code registers each live session as ~/.claude/sessions/<pid>.json.
/// The file is not always cleaned up after a crash, so every entry is confirmed
/// against the running process before it counts.
func readAgentSessions() -> [AgentSession] {
    let dir = NSHomeDirectory() + "/.claude/sessions"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }

    var out: [AgentSession] = []
    for name in names where name.hasSuffix(".json") {
        guard let data = FileManager.default.contents(atPath: dir + "/" + name),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidNum = root["pid"] as? Int
        else { continue }

        let pid = pid_t(pidNum)
        // kill(pid, 0) succeeds only if the process exists and we may signal it.
        guard kill(pid, 0) == 0 || errno == EPERM else { continue }

        out.append(AgentSession(
            pid: pid,
            name: (root["name"] as? String) ?? "session \(pid)",
            cwd: (root["cwd"] as? String) ?? "",
            status: (root["status"] as? String) ?? "unknown",
            sessionId: (root["sessionId"] as? String) ?? "",
            statusSince: (root["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            waitingFor: root["waitingFor"] as? String,
            startedAt: (root["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }))
    }
    return out
}

/// Transcripts live under a slug of the cwd with every "/" replaced by "-".
func transcriptPath(for session: AgentSession) -> String? {
    guard !session.cwd.isEmpty, !session.sessionId.isEmpty else { return nil }
    let slug = session.cwd.replacingOccurrences(of: "/", with: "-")
    return "\(NSHomeDirectory())/.claude/projects/\(slug)/\(session.sessionId).jsonl"
}

/// A parent blocked on a foreground subagent writes nothing itself, so the
/// subagents' transcripts count as activity too.
func lastWrite(transcript path: String) -> Date? {
    let fm = FileManager.default
    var paths = [path]
    let subdir = String(path.dropLast(".jsonl".count)) + "/subagents"
    if let names = try? fm.contentsOfDirectory(atPath: subdir) {
        paths += names.filter { $0.hasSuffix(".jsonl") }.map { subdir + "/" + $0 }
    }
    return paths.compactMap { try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.max()
}

/// Blank run the spinner view is drawn over. Must be at least as wide as the
/// spinner or it overlaps the count; measured at 15.12pt for a 12pt spinner.
let spinnerPlaceholder = "\u{2007}\u{2007}"

/// Menu bar suffix, or nil when nothing is running. Shared by the GUI and --dump
/// so what gets verified on the command line is what actually gets displayed.
func agentSuffix(_ snap: AgentSnapshot) -> String? {
    guard snap.anyRunning else { return nil }
    var label = "\(spinnerPlaceholder) \(snap.busyCount) busy"
    if snap.subagentCount > 0 { label += " (+\(snap.subagentCount))" }
    return label
}

/// Menu bar prefix counting sessions blocked on you, or nil when none are.
func waitingBadge(_ snap: AgentSnapshot) -> String? {
    let n = snap.waiting.count
    return n > 0 ? "\u{2691}\(n)" : nil
}

/// "<1m", "32m", "3h 24m", "2d 4h".
func formatDuration(_ secs: TimeInterval) -> String {
    let s = Int(secs)
    if s < 60 { return "<1m" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

/// Holds what must survive between scans: transcript read offsets and branch
/// lookups. Not thread-safe; drive it from one serial queue.
final class SessionScanner {
    private let reader = TranscriptReader()
    private var branches: [String: (branch: String?, at: Date)] = [:]

    /// `pinned` sessions whose process has exited are kept in the snapshot with
    /// status "exited", so keep-warm and the menu still see their cache state.
    func snapshot(pinned: [Pin] = []) -> AgentSnapshot {
        var sessions = readAgentSessions()
        let live = Set(sessions.map(\.sessionId))
        for pin in pinned where !live.contains(pin.sessionId) {
            guard let cwd = pin.cwd else { continue }
            sessions.append(AgentSession(pid: 0, name: pin.label ?? pin.sessionId, cwd: cwd, status: "exited",
                                         sessionId: pin.sessionId, statusSince: nil, waitingFor: nil))
        }
        let titles = conductorTitles()
        var watched = Set<String>()
        for i in sessions.indices {
            if let path = transcriptPath(for: sessions[i]), let state = reader.update(path: path) {
                watched.insert(path)
                sessions[i].subagents = state.pendingAgents.count
                sessions[i].contextTokens = state.contextTokens
                sessions[i].cacheHit = state.cacheHit
                sessions[i].lastRequestAt = state.lastRequestAt
                sessions[i].cacheTTL = state.cacheTTL
                sessions[i].lastWriteAt = lastWrite(transcript: path)
            }
            if sessions[i].status == "exited" {
                sessions[i].label = sessions[i].name
            } else if let title = titles[sessions[i].sessionId] {
                sessions[i].label = truncate(title, 34)
                sessions[i].fromConductor = true
            } else if let branch = branch(sessions[i].cwd) {
                sessions[i].label = truncate(branch, 34)
            } else {
                sessions[i].label = sessions[i].name
            }
        }
        reader.retain(only: watched)
        return AgentSnapshot(sessions: sessions.sorted { $0.label < $1.label })
    }

    /// Spawning git for every session every minute is wasted work; branches
    /// rarely change, so a few minutes of staleness is fine.
    private func branch(_ cwd: String) -> String? {
        if let hit = branches[cwd], Date().timeIntervalSince(hit.at) < 300 { return hit.branch }
        let b = gitBranch(cwd)
        branches[cwd] = (b, Date())
        return b
    }
}
