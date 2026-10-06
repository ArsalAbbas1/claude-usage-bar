import Foundation
let fixture = "/tmp/agent-fixture.jsonl"
var failed = false
func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    if got != want { failed = true }
    print("\(got == want ? "PASS" : "FAIL")  \(label): got \(got), want \(want)")
}
func write(_ lines: [String]) {
    try? (lines.map { $0 + "\n" }.joined()).write(toFile: fixture, atomically: true, encoding: .utf8)
}
func append(_ s: String) {
    let h = FileHandle(forWritingAtPath: fixture)!
    h.seekToEndOfFile()
    h.write(s.data(using: .utf8)!)
    h.closeFile()
}
func appendBytes(_ d: Data) {
    let h = FileHandle(forWritingAtPath: fixture)!
    h.seekToEndOfFile()
    h.write(d)
    h.closeFile()
}
func pending(_ lines: [String]) -> Int {
    write(lines)
    return TranscriptReader().update(path: fixture)?.pendingAgents.count ?? -1
}

let launch = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_A","name":"Agent","input":{}}]}}"#
let launch2 = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_B","name":"Agent","input":{}}]}}"#
let resultA = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_A","content":"done"}]}}"#
let asyncAckA = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_A","content":"Async agent launched"}]},"toolUseResult":{"isAsync":true,"status":"async_launched"}}"#
let queuedDoneA = #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>x</task-id>\n<tool-use-id>toolu_A</tool-use-id>\n</task-notification>"}"#
let userDoneA = #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<tool-use-id>toolu_A</tool-use-id>\n</task-notification>"}}"#
let otherTool = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_C","name":"Bash","input":{}}]}}"#

// Subagents
check("empty transcript", pending([]), 0)
check("one launched, no result", pending([launch]), 1)
check("launched then finished", pending([launch, resultA]), 0)
check("two launched, one finished", pending([launch, launch2, resultA]), 1)
check("ignores non-Agent tools", pending([otherTool, launch, resultA]), 0)
check("background launch ack is not completion", pending([launch, asyncAckA]), 1)
check("background done via queued notification", pending([launch, asyncAckA, queuedDoneA]), 0)
check("background done via user notification", pending([launch, asyncAckA, userDoneA]), 0)
check("missing file", TranscriptReader().update(path: "/tmp/does-not-exist.jsonl") == nil, true)

// Context size
func usageLine(id: String, read: Int, write: Int, input: Int) -> String {
    #"{"type":"assistant","message":{"id":"\#(id)","role":"assistant","content":[{"type":"text","text":"—"}],"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write)}}}"#
}
let synthetic = #"{"type":"assistant","message":{"id":"msg_syn","role":"assistant","content":[],"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
write([usageLine(id: "msg_1", read: 0, write: 50_000, input: 10),
       usageLine(id: "msg_2", read: 90_000, write: 10_000, input: 5),
       synthetic])
check("context = last real request's input", TranscriptReader().update(path: fixture)?.contextTokens, 100_005)

// Incremental reading
let reader = TranscriptReader()
write([launch])
reader.update(path: fixture)
append(String(resultA.prefix(40)))
check("partial line not consumed yet", reader.update(path: fixture)?.pendingAgents.count, 1)
append(String(resultA.dropFirst(40)) + "\n")
check("completed line consumed on next pass", reader.update(path: fixture)?.pendingAgents.count, 0)

// A multi-byte character split across two writes must not poison either pass.
let r2 = TranscriptReader()
write([])
let line = Data((usageLine(id: "msg_u", read: 1, write: 1, input: 1) + "\n").utf8)
let dash = line.firstIndex(of: 0xE2)!   // first byte of "—"
appendBytes(line[..<(dash + 1)])
r2.update(path: fixture)
appendBytes(line[(dash + 1)...])
check("multi-byte split across passes", r2.update(path: fixture)?.contextTokens, 3)

write([launch])
let r3 = TranscriptReader()
r3.update(path: fixture)
write([])
check("rewritten (shrunk) file resets state", r3.update(path: fixture)?.pendingAgents.count, 0)

// Sessions
let now = Date()
func session(_ status: String, since: TimeInterval, lastWrite: TimeInterval? = nil) -> AgentSession {
    var a = AgentSession(pid: 1, name: status, cwd: "", status: status, sessionId: "s",
                         statusSince: now.addingTimeInterval(-since), waitingFor: nil)
    a.lastWriteAt = lastWrite.map { now.addingTimeInterval(-$0) }
    return a
}
let snap = AgentSnapshot(sessions: [session("waiting", since: 60), session("idle", since: 9),
                                    session("waiting", since: 3600), session("busy", since: 5)])
check("longest wait listed first", snap.waiting.map { Int(now.timeIntervalSince($0.statusSince!)) }, [3600, 60])
check("idle excludes busy and waiting", snap.idle.count, 1)
check("badge counts waiting", waitingBadge(snap), "\u{2691}2")
check("no badge when nothing waits", waitingBadge(AgentSnapshot(sessions: [session("busy", since: 1)])), nil)
check("busy and quiet past threshold is silent",
      session("busy", since: 900, lastWrite: 700).silence(at: now).map(Int.init), 700)
check("busy and writing is not silent", session("busy", since: 900, lastWrite: 30).silence(at: now) == nil, true)
check("idle is never silent", session("idle", since: 900, lastWrite: 900).silence(at: now) == nil, true)

// Formatting
check("duration <1m", formatDuration(59), "<1m")
check("duration m", formatDuration(32 * 60), "32m")
check("duration h m", formatDuration(3 * 3600 + 24 * 60), "3h 24m")
check("duration d h", formatDuration(2 * 86400 + 4 * 3600), "2d 4h")
check("tokens k", formatTokens(313_300), "313k")
check("tokens M", formatTokens(1_250_000), "1.2M")
check("tokens small", formatTokens(512), "512")

// Pace
let reset = now.addingTimeInterval(2 * 3600)
func tracker(_ points: [(minsAgo: Double, pct: Double)], resetsAt: Date = reset) -> PaceTracker {
    let t = PaceTracker()
    for p in points { t.record(pct: p.pct, resetsAt: resetsAt, at: now.addingTimeInterval(-p.minsAgo * 60)) }
    return t
}
check("too little history", tracker([(10, 20), (5, 22), (0, 24)]).forecast(now: now), .measuring)
check("too few readings", tracker([(20, 20), (0, 24)]).forecast(now: now), .measuring)
// 1 point per minute from 40% now: 100% in 60 minutes, before the 2h reset.
check("full before reset", tracker([(30, 10), (15, 25), (0, 40)]).forecast(now: now),
      .full(at: now.addingTimeInterval(60 * 60)))
// 0.1 point per minute: +12 over the remaining 120 minutes.
check("on pace", tracker([(30, 37), (15, 38.5), (0, 40)]).forecast(now: now), .onPace(atReset: 52))
check("flat usage stays put", tracker([(30, 40), (15, 40), (0, 40)]).forecast(now: now), .onPace(atReset: 40))
let rolled = tracker([(50, 80), (40, 90), (30, 95)])
rolled.record(pct: 2, resetsAt: now.addingTimeInterval(5 * 3600), at: now)
check("new window drops old readings", rolled.forecast(now: now), .measuring)
let jitter = tracker([(30, 10), (15, 25)])
jitter.record(pct: 40, resetsAt: reset.addingTimeInterval(1), at: now)
check("reset jitter is the same window", jitter.forecast(now: now), .full(at: now.addingTimeInterval(60 * 60)))

// Cache state from the transcript
let ts = "2026-10-05T23:20:38.013Z"
let warmLine = #"{"type":"assistant","timestamp":"\#(ts)","message":{"id":"m1","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_read_input_tokens":63277,"cache_creation_input_tokens":443,"cache_creation":{"ephemeral_1h_input_tokens":443,"ephemeral_5m_input_tokens":0}}}}"#
let readOnlyLine = #"{"type":"assistant","timestamp":"2026-10-05T23:30:00.000Z","message":{"id":"m2","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_read_input_tokens":63720,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}}"#
write([warmLine])
let cs = TranscriptReader().update(path: fixture)
check("1h TTL from cache write", cs?.cacheTTL, 3600)
check("cache hit share", cs.flatMap { $0.cacheHit.map { Int(($0 * 1000).rounded()) } }, 993)
check("request time from timestamp", cs?.lastRequestAt.map { Int($0.timeIntervalSince1970) }, 1791242438)
write([warmLine, readOnlyLine])
check("read-only request keeps prior TTL", TranscriptReader().update(path: fixture)?.cacheTTL, 3600)
check("5m TTL", cacheTTL(from: ["cache_creation": ["ephemeral_5m_input_tokens": 10, "ephemeral_1h_input_tokens": 0]]), 300)

// Keep-warm scheduling
func idle(requestAgo: TimeInterval, ttl: TimeInterval = 3600, status: String = "idle") -> AgentSession {
    var a = session(status, since: requestAgo)
    a.lastRequestAt = now.addingTimeInterval(-requestAgo)
    a.cacheTTL = ttl
    a.cacheHit = 0.97
    return a
}
let pin = Pin(sessionId: "s", pinnedAt: now.addingTimeInterval(-7200))
check("fresh cache is not due", pingDue(idle(requestAgo: 20 * 60), pin: pin, now: now), false)
check("inside the lead is due", pingDue(idle(requestAgo: 52 * 60), pin: pin, now: now), true)
check("cold is never pinged", pingDue(idle(requestAgo: 61 * 60), pin: pin, now: now), false)
check("busy is never pinged", pingDue(idle(requestAgo: 52 * 60, status: "busy"), pin: pin, now: now), false)
check("waiting can be pinged", pingDue(idle(requestAgo: 52 * 60, status: "waiting"), pin: pin, now: now), true)
check("5m TTL due at 3.5m", pingDue(idle(requestAgo: 210, ttl: 300), pin: pin, now: now), true)
var pinged = pin
pinged.lastPingAt = now.addingTimeInterval(-5 * 60)
check("recent ping resets the clock", pingDue(idle(requestAgo: 52 * 60), pin: pinged, now: now), false)
check("ping extends remaining TTL",
      cacheState(idle(requestAgo: 52 * 60), pin: pinged).map { Int($0.remaining(at: now)) }, 55 * 60)

// Pin store
let pinPath = "/tmp/agent-fixture-pins.json"
try? FileManager.default.removeItem(atPath: pinPath)
let store = PinStore(path: pinPath)
store.toggle("a", now: now)
store.toggle("b", now: now.addingTimeInterval(-9 * 3600))
store.recordPing("a", at: now)
check("pins persist", PinStore(path: pinPath).pins.keys.sorted(), ["a", "b"])
check("ping time persists", PinStore(path: pinPath).pins["a"]?.lastPingAt.map { Int($0.timeIntervalSince1970) },
      Int(now.timeIntervalSince1970))
store.prune(now: now)
check("old pin expires", store.pins.keys.sorted(), ["a"])
store.prune(now: now)
check("ended session stays pinned", store.pins.keys.sorted(), ["a"])
store.remove("a")
store.toggle("c", now: now)
store.toggle("c", now: now)
check("toggle twice unpins", PinStore(path: pinPath).pins.isEmpty, true)

// Ping command
let conductorArgs = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                     "--thinking", "adaptive", "--effort", "medium", "--max-turns", "1000",
                     "--model", "claude-opus-5-5[1m]", "--permission-prompt-tool", "stdio",
                     "--resume=old-id", "--session-mirror", "--disallowedTools", "AskUserQuestion",
                     "--setting-sources=user,project,local", "--permission-mode", "bypassPermissions",
                     "--session-id", "x"]
let built = pingArguments(from: conductorArgs, sessionId: "sid")
check("keeps prefix-shaping flags", Array(built.prefix(9)),
      ["--thinking", "adaptive", "--effort", "medium", "--model", "claude-opus-5-5[1m]",
       "--disallowedTools", "AskUserQuestion", "--setting-sources=user,project,local"])
check("drops I/O, identity and permission flags",
      built.contains { ["stream-json", "--verbose", "stdio", "--resume=old-id", "bypassPermissions", "x", "1000", "--session-mirror"].contains($0) }, false)
check("resumes the registry session, forked and unpersisted",
      built.contains("sid") && built.contains("--fork-session") && built.contains("--no-session-persistence"), true)
check("pings skip the skill listing", built.contains("--disable-slash-commands"), true)

let okOut = Data(#"{"type":"result","is_error":false,"result":"ok","total_cost_usd":0.7350,"usage":{"input_tokens":2,"cache_read_input_tokens":63720,"cache_creation_input_tokens":1825}}"#.utf8)
if case .success(let r) = parsePingOutput(okOut) {
    check("ping output parsed", [r.cacheRead, r.cacheWrite, r.input], [63720, 1825, 2])
} else { check("ping output parsed", false, true) }
let errOut = Data(#"{"type":"result","is_error":true,"result":"No conversation found"}"#.utf8)
if case .failure(.failed(let msg)) = parsePingOutput(errOut) {
    check("ping error surfaced", msg.contains("No conversation found"), true)
} else { check("ping error surfaced", false, true) }

// An exited pinned session stays visible with its cache state
let exitedPin = Pin(sessionId: "no-such-session", pinnedAt: now, lastPingAt: nil, cwd: "/tmp/nowhere",
                    label: "Old chat", exe: "/bin/true", args: [])
let ex = SessionScanner().snapshot(pinned: [exitedPin]).sessions.first { $0.sessionId == "no-such-session" }
check("exited pin kept in snapshot", ex?.status, "exited")
check("exited pin keeps its label", ex?.label, "Old chat")
check("exited pin uses captured launch",
      pingLaunch(ex!, pin: exitedPin, live: []).map { $0.exe }, "/bin/true")
check("no captured launch, no ping", pingLaunch(ex!, pin: Pin(sessionId: "x", pinnedAt: now), live: []) == nil, true)

// Memory: session trees
func proc(_ pid: pid_t, _ ppid: pid_t, _ name: String, mb: UInt64, path: String = "") -> Proc {
    Proc(pid: pid, ppid: ppid, pgid: pid, name: name, started: 1, path: path, bytes: mb << 20)
}
/// Registered `registeredAt` seconds into 1970; the processes below started 1 µs into it.
func live(_ pid: pid_t, _ label: String, registeredAt: TimeInterval? = 1) -> AgentSession {
    var a = AgentSession(pid: pid, name: label, cwd: "", status: "busy", sessionId: label, statusSince: nil,
                         waitingFor: nil, startedAt: registeredAt.map { Date(timeIntervalSince1970: $0) })
    a.label = label
    return a
}
let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
let conductorClaude = "/Users/u/Library/Application Support/com.conductor.app/agent-binaries/claude/2.1.284/claude"
let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
let procs = [
    proc(100, 1, "claude", mb: 300),
    proc(101, 100, "zsh", mb: 3),               // a Bash tool call
    proc(102, 101, "python3.12", mb: 900),
    proc(103, 102, "python3.12", mb: 200),
    proc(104, 100, "node", mb: 80),             // an MCP server
    proc(200, 1, "claude", mb: 250),            // a second session, nothing running
    proc(300, 1, "Google Chrome", mb: 4000, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    proc(301, 300, "Google Chrome He", mb: 2000, path: chromeHelper),
    proc(400, 1, "claude", mb: 150, path: conductorClaude),  // not a registered session
    proc(500, 1, "com.apple.WebKit", mb: 700, path: webContent),
]
let mem = sessionMemory(procs, sessions: [live(100, "one"), live(200, "two"), live(999, "gone")])
check("sessions whose process is gone are dropped", mem.map(\.pid), [100, 200])
check("claude's own memory", mem[0].ownBytes >> 20, 300)
check("one command per child, largest first", mem[0].commands.map(\.root.pid), [101, 104])
check("a command holds everything under its root", mem[0].commands[0].procs.map(\.pid).sorted(), [101, 102, 103])
check("a command is named after its largest process", mem[0].commands[0].name, "python3.12")
check("session total", mem[0].bytes >> 20, 1483)
check("an idle session has no commands", mem[1].commands.isEmpty, true)
let nested = sessionMemory(procs + [proc(600, 102, "claude", mb: 400)], sessions: [live(100, "outer"), live(600, "inner")])
check("a session started inside another is not counted in it", nested[0].bytes >> 20, 1483)
check("it is counted as itself", nested[1].ownBytes >> 20, 400)
// A process that started after the entry was written has a reused pid.
check("a stale entry is not a session", sessionMemory(procs, sessions: [live(100, "stale", registeredAt: 0)]).isEmpty, true)
check("nor is one without a start time", sessionMemory(procs, sessions: [live(100, "old", registeredAt: nil)]).isEmpty, true)
check("a stale entry does not hide a command's process",
      sessionMemory(procs, sessions: [live(100, "one"), live(102, "stale", registeredAt: 0)]).map { $0.bytes >> 20 }, [1483])

// Memory: largest apps
let apps = largestApps(procs, sessions: mem)
check("helpers count toward their app", apps.first.map { "\($0.name) \($0.bytes >> 20)" }, "Google Chrome 6000")
check("sessions count as Claude Code", apps.first { $0.name == "Claude Code" }.map { $0.bytes >> 20 }, 1733)
check("a support folder named like a bundle is not an app", appName(procs[8]), "claude")
check("web views count as WebKit", appName(procs[9]), "WebKit")
check("no path falls back to the process name", appName(proc(1, 0, "launchd", mb: 1)), "launchd")
check("only the largest are kept", largestApps(procs, sessions: mem, limit: 2).count, 2)
check("bytes in GB", formatBytes(1_503_238_553), "1.4 GB")
check("bytes in MB", formatBytes(900 << 20), "900 MB")
check("badge only under pressure", [memoryBadge(.normal), memoryBadge(.warning), memoryBadge(.critical)], [nil, "mem", "mem"])

// Memory: the real process table
let me = readProcesses()?.first { $0.pid == getpid() }
check("reads this process and its parent", me?.ppid, getppid())
check("measures its footprint", (me?.bytes ?? 0) > 0, true)
check("reads its executable path", me?.path.hasSuffix("/agenttest"), true)

// Memory caps
func snapshot(_ sessions: [SessionMemory], _ pressure: MemoryPressure = .normal) -> MemorySnapshot {
    MemorySnapshot(pressure: pressure, swapBytes: 0, sessions: sessions, apps: [])
}
/// `processes` processes sharing `mb`, the first one the root.
func command(_ pid: pid_t, mb: UInt64, processes: Int = 1) -> MemoryCommand {
    MemoryCommand(procs: (0..<processes).map {
        proc(pid + pid_t($0), $0 == 0 ? 1 : pid, "python3.12", mb: mb / UInt64(processes))
    })
}
func sessionWith(_ pid: pid_t, own mb: UInt64 = 300, _ commands: [MemoryCommand]) -> SessionMemory {
    SessionMemory(pid: pid, label: "s\(pid)", ownBytes: mb << 20, commands: commands.sorted { $0.bytes > $1.bytes })
}
func actions(_ m: MemorySnapshot, _ caps: MemoryCaps, stopping: Set<pid_t> = [], lastStop: Date? = nil,
             lastCritical: Date? = nil) -> [String] {
    memoryActions(m, caps: caps, stopping: stopping, lastStop: lastStop, lastCritical: lastCritical, now: now).map {
        if case .stop(let c, _, let reason) = $0 { return "stop \(c.root.pid): \(reason)" }
        return "notify"
    }
}
let heavy = sessionWith(100, [command(110, mb: 3500), command(120, mb: 2900)])
let several = sessionWith(400, [command(410, mb: 2100), command(420, mb: 2000), command(430, mb: 1000)])
check("caps are off by default", loadMemoryCaps(path: "/tmp/no-such-config.json"), MemoryCaps())
check("nothing is stopped with caps off", actions(snapshot([heavy]), MemoryCaps()), [])
check("a command over the cap is stopped", actions(snapshot([heavy]), MemoryCaps(commandGB: 3)),
      ["stop 110: over the 3 GB command cap"])
check("a fork bomb is one command", actions(snapshot([sessionWith(300, [command(310, mb: 11_000, processes: 80)])]),
                                            MemoryCaps(commandGB: 3)),
      ["stop 310: over the 3 GB command cap"])
check("the claude process is never a target",
      actions(snapshot([sessionWith(200, own: 10_000, [command(210, mb: 50)])]), MemoryCaps(commandGB: 2, sessionGB: 4)), [])
check("a session over its cap loses its largest command", actions(snapshot([several]), MemoryCaps(sessionGB: 4)),
      ["stop 410: its session's commands passed the 4 GB session cap"])
check("a command being stopped is not stopped again", actions(snapshot([heavy]), MemoryCaps(commandGB: 3), stopping: [110]), [])
check("nor counted toward its session's cap", actions(snapshot([several]), MemoryCaps(sessionGB: 4), stopping: [410]), [])
check("a custom cap reads as given", MemoryCaps(commandGB: 0.15).summary.hasPrefix("command cap 0.15 GB"), true)

let critical = snapshot([heavy], .critical)
let stopAtCritical = MemoryCaps(stopAtCritical: true)
check("critical notifies by default", actions(critical, MemoryCaps()), ["notify"])
check("once per cooldown", actions(critical, MemoryCaps(), lastCritical: now.addingTimeInterval(-60)), [])
check("and again after it", actions(critical, MemoryCaps(), lastCritical: now.addingTimeInterval(-criticalCooldown)), ["notify"])
check("critical can stop the largest command", actions(critical, stopAtCritical), ["stop 110: memory pressure is critical"])
check("a command too small to help is left alone",
      actions(snapshot([sessionWith(500, [command(510, mb: 600)])], .critical), stopAtCritical), ["notify"])
check("a cap stop is not followed by a critical one in the same sample",
      actions(critical, MemoryCaps(commandGB: 3, stopAtCritical: true)), ["stop 110: over the 3 GB command cap", "notify"])
check("nor while an earlier stop may still be freeing memory",
      actions(critical, stopAtCritical, lastStop: now.addingTimeInterval(-4)), ["notify"])
check("but after it has had time to", actions(critical, stopAtCritical, lastStop: now.addingTimeInterval(-20)),
      ["stop 110: memory pressure is critical"])
check("warning stops nothing", actions(snapshot([heavy], .warning), stopAtCritical), [])
check("a cap outside 0.5–512 GB is off", [0, -1, 0.4, 1e12, Double.nan, Double.infinity, 0.5, 512].map { validCap($0) },
      [nil, nil, nil, nil, nil, nil, 0.5, 512])

let configFixture = "/tmp/agent-fixture-config.json"
try? #"{"theme":"htop"}"#.write(toFile: configFixture, atomically: true, encoding: .utf8)
saveMemoryCaps(MemoryCaps(commandGB: 3, stopAtCritical: true), path: configFixture)
check("caps persist", loadMemoryCaps(path: configFixture), MemoryCaps(commandGB: 3, stopAtCritical: true))
let savedRoot = FileManager.default.contents(atPath: configFixture)
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
check("other settings in the file are kept", savedRoot?["theme"] as? String, "htop")
saveMemoryCaps(MemoryCaps(), path: configFixture)
check("a cap turned off stays off", loadMemoryCaps(path: configFixture), MemoryCaps())
try? #"{"memory":{"commandCapGB":0,"sessionCapGB":1e12,"atCritical":"notify"}}"#
    .write(toFile: configFixture, atomically: true, encoding: .utf8)
check("a cap edited out of range loads as off", loadMemoryCaps(path: configFixture), MemoryCaps())
let handEdit = #"{"theme":"htop""#
try? handEdit.write(toFile: configFixture, atomically: true, encoding: .utf8)
check("a file that does not parse is not saved over", saveMemoryCaps(MemoryCaps(commandGB: 3), path: configFixture), false)
check("and is left as it was", try? String(contentsOfFile: configFixture, encoding: .utf8), handEdit)

// Memory caps: stopping real processes, all spawned here in their own group
func spawnGroup(_ script: String) -> pid_t {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)
    var pid: pid_t = 0
    let words: [String] = ["/bin/sh", "-c", script]
    let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
    let rc = posix_spawn(&pid, "/bin/sh", nil, &attr, argv, nil)
    posix_spawnattr_destroy(&attr)
    argv.forEach { free($0) }
    // 0 is "my own group" to waitpid and killpg, so a failed spawn must not leave it.
    return rc == 0 ? pid : -1
}
/// The process and its children once it has started `children` of them.
func sampleGroup(_ pid: pid_t, children: Int) -> (root: Proc, children: [pid_t])? {
    for _ in 0..<40 where pid > 0 {
        let table = readProcesses() ?? []
        let kids = table.filter { $0.ppid == pid }.map(\.pid)
        if let root = table.first(where: { $0.pid == pid }), kids.count >= children { return (root, kids) }
        usleep(50_000)
    }
    return nil
}
/// The signal that ended `pid`, or nil if it is still running after `secs`.
func endedBy(_ pid: pid_t, within secs: Double) -> Int32? {
    var status: Int32 = 0
    for _ in 0..<max(1, Int(secs * 20)) {
        if waitpid(pid, &status, WNOHANG) == pid { return status & 0x7f }
        usleep(50_000)
    }
    return nil
}
func gone(_ pid: pid_t) -> Bool {
    for _ in 0..<40 where kill(pid, 0) == 0 { usleep(50_000) }
    return kill(pid, 0) != 0
}

let group = spawnGroup("/bin/sleep 30 & /bin/sleep 30 & wait")
if let g = sampleGroup(group, children: 2) {
    check("the spawned shell leads its own group", g.root.pgid, group)
    // Only the root is sampled: the group is what reaches its children.
    check("SIGTERM is delivered", deliver(SIGTERM, to: MemoryCommand(procs: [g.root]), protected: []) > 0, true)
    check("the shell ends on SIGTERM", endedBy(group, within: 3), SIGTERM)
    check("so do its children, which were not sampled", g.children.allSatisfy(gone), true)
} else { check("group started", false, true) }

// The trailing `:` keeps sh from exec'ing sleep, so a child means the trap is set.
let stubborn = spawnGroup("trap '' TERM; /bin/sleep 30; :")
if let s = sampleGroup(stubborn, children: 1) {
    let cmd = MemoryCommand(procs: [s.root])
    _ = deliver(SIGTERM, to: cmd, protected: [])
    check("a command can ignore SIGTERM", endedBy(stubborn, within: 1), nil)
    check("SIGKILL reaches it", deliver(SIGKILL, to: cmd, protected: []) > 0, true)
    check("and ends it", endedBy(stubborn, within: 3), SIGKILL)
} else { check("stubborn command started", false, true) }

let decoy = spawnGroup("/bin/sleep 30")
if let d = sampleGroup(decoy, children: 0), let me {
    let reused = Proc(pid: decoy, ppid: d.root.ppid, pgid: d.root.pgid, name: "sleep", started: d.root.started + 1)
    check("a reused pid is left alone", deliver(SIGTERM, to: MemoryCommand(procs: [reused]), protected: []), 0)
    check("a protected pid is left alone", deliver(SIGTERM, to: MemoryCommand(procs: [d.root]), protected: [decoy]), 0)
    check("this app is left alone", deliver(SIGTERM, to: MemoryCommand(procs: [me]), protected: []), 0)
    check("the decoy is still running", endedBy(decoy, within: 0.2), nil)
} else { check("decoy started", false, true) }

// Protected pids come from the registry, where an entry can outlive its process.
let myStart = Double(me?.started ?? 0) / 1_000_000
check("a session's process is protected", sessionPids([live(getpid(), "me", registeredAt: myStart + 1)]), [getpid()])
check("so is one whose entry has no start time", sessionPids([live(getpid(), "old", registeredAt: nil)]), [getpid()])
check("a stale entry's pid is not", sessionPids([live(getpid(), "stale", registeredAt: myStart - 1)]), [])

// A session started inside a command shares the command's group.
let shared = spawnGroup("/bin/sleep 30 & /bin/sleep 30 & wait")
if let g = sampleGroup(shared, children: 2) {
    let cmd = MemoryCommand(procs: [g.root])
    _ = deliver(SIGTERM, to: cmd, protected: [g.children[0]])
    check("a group holding a protected pid is signalled one process at a time", endedBy(shared, within: 3), SIGTERM)
    check("so the protected pid and its group are left running", g.children.allSatisfy { kill($0, 0) == 0 }, true)
    check("once the root is gone, its group's leftovers are reached", deliver(SIGKILL, to: cmd, protected: []) > 0, true)
    check("and end", g.children.allSatisfy(gone), true)
} else { check("shared group started", false, true) }
// Only a child still running is ours to kill: a reaped one's pid may be reused.
for pid in [group, stubborn, decoy, shared] where pid > 0 && waitpid(pid, nil, WNOHANG) == 0 {
    killpg(pid, SIGKILL)
    _ = endedBy(pid, within: 1)
}

exit(failed ? 1 : 0)
