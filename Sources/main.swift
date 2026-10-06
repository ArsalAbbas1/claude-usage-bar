import Cocoa
import ServiceManagement
import UserNotifications

// MARK: - Model

struct Window {
    let key: String
    let label: String
    let utilization: Double
    let resetsAt: Date?
}

struct ExtraUsage {
    let used: Double
    let limit: Double
    let currency: String
    let utilization: Double
    let enabled: Bool
}

struct Usage {
    let windows: [Window]
    let extra: ExtraUsage?
    let fetchedAt: Date
    /// True when the numbers came from Claude Code's on-disk cache rather than the API.
    let fromCache: Bool

    var binding: Window? {
        windows.max(by: { $0.utilization < $1.utilization })
    }

    /// Older than two missed polls. A live reading that stops refreshing is just
    /// as stale as a cached one, and used to display with no marker at all.
    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 660
    }
}

// MARK: - Fetching

enum FetchError: Error {
    case noToken
    case http(Int, retryAfter: TimeInterval?)
    case malformed
}

/// Windows the API returns that are worth surfacing, in display order.
/// The API also returns a long tail of null-valued codenamed buckets; those are skipped.
let knownWindows: [(String, String)] = [
    ("five_hour", "5-hour"),
    ("seven_day", "7-day"),
    ("seven_day_opus", "7-day Opus"),
    ("seven_day_sonnet", "7-day Sonnet"),
    ("seven_day_oauth_apps", "7-day apps"),
]

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseDate(_ s: Any?) -> Date? {
    guard let s = s as? String else { return nil }
    if let d = isoFormatter.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
}

func parseUsage(_ root: [String: Any], fetchedAt: Date, fromCache: Bool) -> Usage {
    var windows: [Window] = []
    for (key, label) in knownWindows {
        guard let entry = root[key] as? [String: Any],
              let util = entry["utilization"] as? Double else { continue }
        windows.append(Window(key: key, label: label, utilization: util,
                              resetsAt: parseDate(entry["resets_at"])))
    }

    var extra: ExtraUsage?
    if let e = root["extra_usage"] as? [String: Any],
       let used = e["used_credits"] as? Double,
       let limit = e["monthly_limit"] as? Double {
        extra = ExtraUsage(used: used,
                           limit: limit,
                           currency: (e["currency"] as? String) ?? "USD",
                           utilization: (e["utilization"] as? Double) ?? 0,
                           enabled: (e["is_enabled"] as? Bool) ?? false)
    }

    return Usage(windows: windows, extra: extra, fetchedAt: fetchedAt, fromCache: fromCache)
}

func oauthToken() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String,
          !token.isEmpty
    else { return nil }
    return token
}

func fetchLive(completion: @escaping (Result<Usage, FetchError>) -> Void) {
    guard let token = oauthToken() else { return completion(.failure(.noToken)) }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.timeoutInterval = 15
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard code == 200 else {
            let retry = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return completion(.failure(.http(code, retryAfter: retry)))
        }
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return completion(.failure(.malformed)) }
        completion(.success(parseUsage(root, fetchedAt: Date(), fromCache: false)))
    }.resume()
}

/// Claude Code caches its last utilization fetch in ~/.claude.json. Used when the
/// API call fails so the bar shows a stale-but-real number instead of nothing.
func readCache() -> Usage? {
    let path = NSHomeDirectory() + "/.claude.json"
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cached = root["cachedUsageUtilization"] as? [String: Any],
          let util = cached["utilization"] as? [String: Any]
    else { return nil }
    let ms = (cached["fetchedAtMs"] as? Double) ?? 0
    return parseUsage(util, fetchedAt: Date(timeIntervalSince1970: ms / 1000), fromCache: true)
}

// MARK: - Formatting

/// String(format:) does not honour width specifiers on %@, so pad explicitly.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func bar(_ pct: Double, width: Int = 10) -> String {
    let filled = max(0, min(width, Int((pct / 100.0 * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
}

func countdown(to date: Date?) -> String {
    guard let date else { return "—" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "now" }
    let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func ago(_ date: Date) -> String {
    let secs = Int(Date().timeIntervalSince(date))
    if secs < 60 { return "just now" }
    if secs < 3600 { return "\(secs / 60)m ago" }
    return "\(secs / 3600)h ago"
}

func color(for pct: Double) -> NSColor {
    if pct >= 90 { return .systemRed }
    if pct >= 70 { return .systemOrange }
    return .labelColor
}

func color(for pressure: MemoryPressure) -> NSColor {
    switch pressure {
    case .normal: return .labelColor
    case .warning: return .systemOrange
    case .critical: return .systemRed
    }
}

/// Compact menu-bar label for a window: "5h", "7d", "7d·O".
func shortLabel(_ key: String) -> String {
    switch key {
    case "five_hour": return "5h"
    case "seven_day": return "7d"
    case "seven_day_opus": return "7d·O"
    case "seven_day_sonnet": return "7d·S"
    default: return "7d·a"
    }
}

/// Menu bar segments, one per window shown. Each carries its own utilisation so it
/// can be coloured independently — a healthy 5h should not inherit a red 7d.
func titleSegments(_ u: Usage) -> [(text: String, pct: Double)] {
    let stale = (u.fromCache || u.isStale) ? "~" : ""
    let shown = u.windows.filter { $0.key == "five_hour" || $0.key == "seven_day" }
    let use = shown.isEmpty ? (u.binding.map { [$0] } ?? []) : shown
    return use.map { ("\(shortLabel($0.key)) \(stale)\(Int($0.utilization.rounded()))%", $0.utilization) }
}

func titleText(_ u: Usage) -> String {
    titleSegments(u).map(\.text).joined(separator: "  ")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    var displayTimer: Timer?
    var agents = AgentSnapshot(sessions: [])
    /// Scans read files and spawn git, so they stay off the main thread. Serial,
    /// because the scanner's read offsets are not safe to share.
    let scanner = SessionScanner()
    let scanQueue = DispatchQueue(label: "claude-usage.scan", qos: .utility)
    static let spinnerSize: CGFloat = 12
    let spinner = SpinnerView(frame: NSRect(x: 0, y: 0, width: spinnerSize, height: spinnerSize))
    /// Live readings of the 5-hour window, for the "full by" forecast.
    let pace = PaceTracker()
    /// One notification per wait: keyed by session and the time the wait began.
    var notifiedWaits = Set<String>()
    var usage: Usage?
    var lastError: String?
    /// Swapping item.menu while the user has it open closes it mid-click, so
    /// refreshes that land during tracking defer their rebuild to menuDidClose.
    var menuIsOpen = false
    /// Holding an activity token keeps App Nap from throttling the poll timer.
    var activity: NSObjectProtocol?
    /// Set when the usage endpoint returns 429. Polling past a rate limit only
    /// deepens it, so scheduled refreshes are skipped until this passes.
    var backoffUntil: Date?
    let pins = PinStore()
    /// Sessions with a ping in flight, so a slow one is not launched twice.
    var pinging = Set<String>()
    /// Last keep-warm outcome per session, shown in its submenu.
    var pinNotes: [String: String] = [:]
    /// Latest memory reading; nil until the first sample lands.
    var memory: MemorySnapshot?
    /// A sample reads every process, so it stays off the main thread.
    let memoryQueue = DispatchQueue(label: "claude-usage.memory", qos: .utility)
    var memoryTimer: Timer?
    /// Samples at once when the kernel changes the pressure level.
    var pressureSource: DispatchSourceMemoryPressure?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Without this, a cmd-dragged position is forgotten on every relaunch.
        item.autosaveName = "ClaudeUsageStatusItem"
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        setTitle("Claude …", pct: 0, dimmed: true)
        refreshAgents()
        rebuildMenu()
        refresh()

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "poll Claude Code usage")

        // Timers do not fire while the machine is asleep, so without this the
        // readout stays frozen at whatever it was when the lid closed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh(manual: true) }

        let t = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Nothing here needs to happen on the dot; slack lets the system batch
        // this wakeup with others instead of waking the CPU on its own.
        t.tolerance = 30
        timer = t

        // Staleness is computed at render time, so without a display-only tick the
        // "~" would never appear precisely when fetching has stopped working.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { _, _ in }

        let display = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshAgents()
        }
        display.tolerance = 15
        displayTimer = display

        let mem = Timer.scheduledTimer(withTimeInterval: memorySampleInterval, repeats: true) { [weak self] _ in
            self?.sampleMemory()
        }
        mem.tolerance = 2
        memoryTimer = mem
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.sampleMemory() }
        source.resume()
        pressureSource = source
        sampleMemory()
    }

    static let barFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    func setTitle(_ text: String, pct: Double, dimmed: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.barFont,
            .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : color(for: pct),
        ]
        item.button?.image = nil
        item.button?.imagePosition = .noImage
        item.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    func setTitle(segments: [(text: String, color: NSColor)]) {
        let out = NSMutableAttributedString()
        for (i, seg) in segments.enumerated() {
            if i > 0 {
                out.append(NSAttributedString(string: "  ", attributes: [.font: Self.barFont]))
            }
            out.append(NSAttributedString(string: seg.text, attributes: [
                .font: Self.barFont,
                .foregroundColor: seg.color,
            ]))
        }
        item.button?.image = nil
        item.button?.imagePosition = .noImage
        item.button?.attributedTitle = out
    }

    func refresh(manual: Bool = false) {
        if !manual, let until = backoffUntil, until > Date() { return }
        // fetchLive shells out to `security` and blocks on it, so it must not run
        // on the main thread. The completion hops back to main itself.
        DispatchQueue.global(qos: .utility).async { [weak self] in
        fetchLive { result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let u):
                    self.usage = u
                    if let w = u.windows.first(where: { $0.key == "five_hour" }), let r = w.resetsAt {
                        self.pace.record(pct: w.utilization, resetsAt: r, at: u.fetchedAt)
                    }
                    self.lastError = nil
                    self.backoffUntil = nil
                case .failure(let e):
                    switch e {
                    case .noToken: self.lastError = "Not signed in to Claude Code"
                    case .http(401, _): self.lastError = "Token expired — run any Claude Code session"
                    case .http(429, let retry):
                        // The endpoint sometimes sends Retry-After: 0 while still
                        // refusing, so a floor is needed or the backoff does nothing.
                        let wait = max(retry ?? 60, 60)
                        self.backoffUntil = Date().addingTimeInterval(wait)
                        self.lastError = "Rate limited — retrying in \(Int(wait))s"
                    case .http(let c, _): self.lastError = "API error \(c)"
                    case .malformed: self.lastError = "Unexpected API response"
                    }
                    // Only fall back to the cache when we have nothing live at all;
                    // a previously-good live reading is fresher than the on-disk one.
                    if self.usage == nil || self.usage?.fromCache == true {
                        self.usage = readCache()
                    }
                }
                self.render()
            }
        }
        }
    }

    func render() {
        guard let u = usage, u.binding != nil else {
            // The first agent scan can land before the first fetch; keep the
            // loading placeholder until a fetch has actually failed.
            if usage != nil || lastError != nil {
                setTitle("Claude ⚠", pct: 0, dimmed: true)
            }
            // Without this the reason (no token, 401, 429) never reaches the menu.
            rebuildMenu()
            return
        }
        renderTitle()
        rebuildMenu()
    }

    /// Title only. The spinner runs several times a second, and rebuilding the
    /// whole menu at that rate would be wasteful.
    func renderTitle() {
        guard let u = usage, u.binding != nil else { return }
        var segs = titleSegments(u).map { (text: $0.text, color: color(for: $0.pct)) }
        if let m = memory, let badge = memoryBadge(m.pressure) {
            segs.insert((text: badge, color: color(for: m.pressure)), at: 0)
        }
        if let badge = waitingBadge(agents) {
            segs.insert((text: badge, color: .systemOrange), at: 0)
        }
        if let suffix = agentSuffix(agents) {
            segs.append((text: suffix, color: .labelColor))
        }
        setTitle(segments: segs)
        positionSpinner()
    }

    /// Parks the spinner over the placeholder gap at the start of the suffix.
    func positionSpinner() {
        guard let button = item.button else { return }
        guard agents.anyRunning else {
            spinner.stop()
            spinner.removeFromSuperview()
            return
        }
        if spinner.superview == nil { button.addSubview(spinner) }

        let size = Self.spinnerSize
        let gap = (spinnerPlaceholder as NSString)
            .size(withAttributes: [.font: Self.barFont]).width
        // Centre it inside the blank run rather than at the run's leading edge,
        // which is what made it sit on top of the count.
        // The title is inset inside the button; measuring from the button's right
        // edge ignores that padding and lands the spinner on top of the count.
        let titleWidth = button.attributedTitle.size().width
        let inset = max(0, (button.bounds.width - titleWidth) / 2)
        let suffixStart = inset + (titleWidth - suffixWidth)
        let x = suffixStart + (gap - size) / 2
        spinner.frame = NSRect(x: x, y: (button.bounds.height - size) / 2,
                               width: size, height: size)
        spinner.start()
    }

    /// Width of the trailing agent suffix, used to place the spinner over its gap.
    var suffixWidth: CGFloat {
        guard let suffix = agentSuffix(agents) else { return 0 }
        return (suffix as NSString)
            .size(withAttributes: [.font: Self.barFont]).width
    }

    func rebuildMenu() {
        guard !menuIsOpen else { return }
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        if let u = usage {
            for w in u.windows {
                let line = String(format: "%@ %@ %3d%%   resets %@",
                                  pad(w.label, 12), bar(w.utilization),
                                  Int(w.utilization.rounded()), countdown(to: w.resetsAt))
                let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                mi.attributedTitle = NSAttributedString(string: line, attributes: [
                    .font: mono, .foregroundColor: color(for: w.utilization),
                ])
                menu.addItem(mi)
                if w.key == "five_hour", !u.fromCache {
                    menu.addItem(paceItem(pace.forecast(), resetsAt: w.resetsAt, font: mono))
                }
            }

            if let e = u.extra, e.enabled {
                menu.addItem(.separator())
                let line = String(format: "%@ %@ %3d%%   %@%.0f of %.0f",
                                  pad("Extra usage", 12), bar(e.utilization),
                                  Int(e.utilization.rounded()),
                                  e.currency == "USD" ? "$" : "", e.used, e.limit)
                let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                mi.attributedTitle = NSAttributedString(string: line, attributes: [
                    .font: mono, .foregroundColor: color(for: e.utilization),
                ])
                menu.addItem(mi)
            }

            menu.addItem(.separator())
            let src = u.fromCache ? "cached from Claude Code"
                : (u.isStale ? "stale — refresh to update" : "live")
            menu.addItem(disabled("Updated \(ago(u.fetchedAt)) · \(src)"))
        }

        let rowFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let now = Date()
        if agents.sessions.isEmpty {
            menu.addItem(disabled("No Claude Code sessions running"))
        }
        if !agents.waiting.isEmpty {
            menu.addItem(disabled("NEEDS YOU"))
            for a in agents.waiting { menu.addItem(sessionItem(a, font: rowFont, now: now)) }
        }
        if !agents.busy.isEmpty {
            menu.addItem(disabled("WORKING"))
            for a in agents.busy { menu.addItem(sessionItem(a, font: rowFont, now: now)) }
        }
        let warm = agents.idle.filter { pins.isPinned($0.sessionId) }
        if !warm.isEmpty {
            menu.addItem(disabled("KEPT WARM"))
            for a in warm { menu.addItem(sessionItem(a, font: rowFont, now: now)) }
        }
        let idle = agents.idle.filter { !pins.isPinned($0.sessionId) }
        if !idle.isEmpty {
            // Idle sessions need nothing from you, so they fold away.
            let fold = NSMenuItem(title: "\(idle.count) idle", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for a in idle { sub.addItem(sessionItem(a, font: rowFont, now: now)) }
            fold.submenu = sub
            menu.addItem(fold)
        }
        menu.addItem(.separator())

        if let m = memory {
            menu.addItem(memoryItem(m, font: mono))
        }
        if let err = lastError {
            menu.addItem(disabled("⚠ \(err)"))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(doRefresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Usage Page", action: #selector(openUsage), keyEquivalent: "u"))
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for mi in menu.items where mi.action != nil && mi.action != #selector(NSApplication.terminate(_:)) {
            mi.target = self
        }
        return menu
    }

    func disabled(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        mi.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return mi
    }

    @objc func doRefresh() {
        refreshAgents()
        refresh(manual: true)
    }

    func refreshAgents() {
        let pinned = Array(pins.pins.values)
        scanQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.scanner.snapshot(pinned: pinned)
            DispatchQueue.main.async {
                self.notifyWaits(snapshot)
                self.agents = snapshot
                self.keepWarm(snapshot)
                self.render()
            }
        }
    }

    /// The title is redrawn only when the pressure level changes: setting it
    /// costs ~13 ms, as measured for the spinner.
    func sampleMemory() {
        let sessions = agents.sessions
        memoryQueue.async { [weak self] in
            guard let snap = takeMemorySnapshot(sessions: sessions) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let levelChanged = self.memory?.pressure != snap.pressure
                self.memory = snap
                if levelChanged { self.renderTitle() }
                self.rebuildMenu()
            }
        }
    }

    /// A session blocked on a dialog makes no progress until you answer it, and
    /// nothing on screen says so when its window is not in front.
    func notifyWaits(_ snapshot: AgentSnapshot) {
        let now = Date()
        var current = Set<String>()
        for a in snapshot.waiting {
            guard let since = a.statusSince else { continue }
            let key = "\(a.sessionId)@\(since.timeIntervalSince1970)"
            current.insert(key)
            guard now.timeIntervalSince(since) >= waitingNotifyAfter,
                  !notifiedWaits.contains(key) else { continue }
            notifiedWaits.insert(key)
            let content = UNMutableNotificationContent()
            content.title = "\(a.label) needs you"
            content.body = "Waiting \(formatDuration(now.timeIntervalSince(since)))"
                + (a.waitingFor.map { " — \($0)" } ?? "")
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
        // Forget waits that ended, so the set does not grow without bound.
        notifiedWaits.formIntersection(current)
    }

    func sessionItem(_ a: AgentSession, font: NSFont, now: Date) -> NSMenuItem {
        let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mi.attributedTitle = sessionRow(a, font: font, now: now, pin: pins.pins[a.sessionId],
                                        memory: memory?.session(a.pid)?.bytes)

        let sub = NSMenu()
        let toggle = NSMenuItem(title: "Keep Cache Warm", action: #selector(togglePin(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = a.sessionId
        toggle.state = pins.isPinned(a.sessionId) ? .on : .off
        sub.addItem(toggle)
        if let note = pinNotes[a.sessionId] { sub.addItem(disabled(note)) }
        if let s = memory?.session(a.pid) {
            let largest = s.commands.first.map { " · largest \($0.name) \(formatBytes($0.bytes))" } ?? ""
            sub.addItem(disabled("Memory \(formatBytes(s.bytes))\(largest)"))
        }
        if a.fromConductor {
            sub.addItem(.separator())
            let open = NSMenuItem(title: "Open in Conductor", action: #selector(openConductor), keyEquivalent: "")
            open.target = self
            sub.addItem(open)
        }
        mi.submenu = sub
        return mi
    }

    @objc func togglePin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        pins.toggle(id)
        if let a = agents.sessions.first(where: { $0.sessionId == id && $0.pid > 0 }) { pins.capture(a) }
        pinNotes[id] = nil
        keepWarm(agents)
        rebuildMenu()
    }

    /// Pings every pinned, idle session whose cache is about to lapse. Runs on
    /// the 60s scan tick; the ping itself is a forked, unpersisted `claude -p`.
    func keepWarm(_ snapshot: AgentSnapshot) {
        pins.prune()
        let live = snapshot.sessions.filter { $0.pid > 0 }
        for a in live where pins.isPinned(a.sessionId) { pins.capture(a) }
        if let five = usage?.windows.first(where: { $0.key == "five_hour" }),
           five.utilization >= keepWarmPauseAbovePct {
            for id in pins.pins.keys { pinNotes[id] = "Paused: 5-hour window at \(Int(five.utilization))%" }
            return
        }
        let now = Date()
        for a in snapshot.sessions {
            guard let pin = pins.pins[a.sessionId], !pinging.contains(a.sessionId) else { continue }
            // Once an exited session goes cold nothing can usefully warm it, so
            // the pin is done. A live one stays pinned for after its next turn.
            if a.pid == 0, let c = cacheState(a, pin: pin), c.remaining(at: now) <= 0 {
                pins.remove(a.sessionId)
                pinNotes[a.sessionId] = nil
                continue
            }
            guard pingDue(a, pin: pin, now: now) else { continue }
            pinging.insert(a.sessionId)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let sentAt = Date()
                let result = runPing(a, pin: pin, live: live)
                logPing(a.label, sessionId: a.sessionId, result, at: sentAt)
                DispatchQueue.main.async { self?.finishPing(a, result, sentAt: sentAt) }
            }
        }
    }

    func finishPing(_ a: AgentSession, _ result: Result<PingResult, PingError>, sentAt: Date) {
        pinging.remove(a.sessionId)
        let clock = DateFormatter()
        clock.timeStyle = .short
        switch result {
        case .success(let r):
            let context = a.contextTokens ?? 0
            if Double(r.cacheRead) < pingMinCacheRead * Double(context) {
                // The ping warmed some other prefix; repeating it would only pay
                // write prices again each time without helping the session.
                pins.remove(a.sessionId)
                pinNotes[a.sessionId] = "Unpinned: ping read \(formatTokens(r.cacheRead)) of \(formatTokens(context)) from cache"
            } else {
                pins.recordPing(a.sessionId, at: sentAt)
                pinNotes[a.sessionId] = "Pinged \(clock.string(from: sentAt)) · \(formatTokens(r.cacheRead)) cached"
            }
        case .failure(let e):
            pinNotes[a.sessionId] = "Ping failed \(clock.string(from: sentAt)): \(e)"
        }
        rebuildMenu()
    }

    func paceItem(_ f: PaceForecast, resetsAt: Date?, font: NSFont) -> NSMenuItem {
        let clock = DateFormatter()
        clock.timeStyle = .short
        let (text, tint): (String, NSColor) = {
            switch f {
            case .measuring:
                return ("measuring pace…", .tertiaryLabelColor)
            case .full(let at):
                let reset = resetsAt.map { ", resets \(clock.string(from: $0))" } ?? ""
                return ("full by \(clock.string(from: at))\(reset)", .systemRed)
            case .onPace(let pct):
                return ("on pace — ~\(Int(pct.rounded()))% at reset", .secondaryLabelColor)
            }
        }()
        let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mi.attributedTitle = NSAttributedString(string: "\(pad("", 12)) \u{21B3} \(text)", attributes: [
            .font: font, .foregroundColor: tint,
        ])
        return mi
    }

    /// Pressure, swap and what Claude Code holds. The submenu names the largest
    /// apps, because the pressure is often not Claude's.
    func memoryItem(_ m: MemorySnapshot, font: NSFont) -> NSMenuItem {
        let line = "\(pad("Memory", 12)) \(m.pressure) · swap \(formatBytes(m.swapBytes))"
            + " · Claude \(formatBytes(m.claudeBytes))"
        let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mi.attributedTitle = NSAttributedString(string: line, attributes: [
            .font: font, .foregroundColor: color(for: m.pressure),
        ])
        let sub = NSMenu()
        sub.addItem(disabled("LARGEST APPS"))
        for app in m.apps {
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.attributedTitle = NSAttributedString(
                string: "\(pad(truncate(app.name, 24), 24)) \(formatBytes(app.bytes))",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            sub.addItem(row)
        }
        mi.submenu = sub
        return mi
    }

    @objc func openConductor() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.conductor.app").first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.conductor.app") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    @objc func openUsage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastError = "Login item failed: \(error.localizedDescription)"
        }
        rebuildMenu()
    }
}

/// One session row: status dot, label, how long it has been in that state, and
/// only the warnings that ask for action (big context, big memory, silence, what
/// it waits on). Shape carries the status as well as colour, so rows stay
/// readable without relying on colour alone.
func sessionRow(_ a: AgentSession, font: NSFont, now: Date, pin: Pin? = nil, memory: UInt64? = nil) -> NSAttributedString {
    let (dot, tint): (String, NSColor) = {
        switch a.status {
        case "busy":    return ("\u{25CF}", .systemGreen)
        case "waiting": return ("\u{25D0}", .systemOrange)
        default:        return ("\u{25CB}", .tertiaryLabelColor)
        }
    }()
    let base: NSColor = a.isBusy || a.isWaiting ? .labelColor : .secondaryLabelColor

    let out = NSMutableAttributedString()
    func add(_ s: String, _ color: NSColor) {
        out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
    }
    add("\(dot) ", tint)
    add(pad(a.label, 36), base)

    let since = a.statusSince.map { " " + formatDuration(now.timeIntervalSince($0)) } ?? ""
    add(pad(a.status + since, 16), a.isWaiting ? .systemOrange : base)

    // A busy session keeps its own cache warm, so only idle and waiting rows say.
    let mark = pin != nil ? "\u{21BB} " : "  "
    if !a.isBusy, let c = cacheState(a, pin: pin) {
        let left = c.remaining(at: now)
        if left > 0 {
            let hit = c.hit.map { "\(Int(($0 * 100).rounded()))% hit · " } ?? ""
            // A low hit on a warm session means something rewrote the prefix.
            let tint: NSColor = (c.hit ?? 1) < 0.8 ? .systemOrange : (pin != nil ? .labelColor : .secondaryLabelColor)
            add(pad(mark + hit + formatDuration(left) + " warm", 22), tint)
        } else {
            add(pad(mark + "cache cold", 22), .tertiaryLabelColor)
        }
    } else {
        add(pad(pin != nil ? mark : "", 22), base)
    }

    if let tokens = a.contextTokens, tokens >= contextWarnTokens {
        add(pad(formatTokens(tokens) + " ctx", 11), tokens >= contextAlertTokens ? .systemRed : .systemOrange)
    } else {
        add(pad("", 11), base)
    }
    if let bytes = memory, bytes >= memoryWarnBytes {
        add("\(formatBytes(bytes)) mem  ", bytes >= memoryAlertBytes ? .systemRed : .systemOrange)
    }
    if a.subagents > 0 { add("+\(a.subagents) agents  ", base) }
    if let quiet = a.silence(at: now) { add("\u{26A0} silent \(formatDuration(quiet))", .systemOrange) }
    if a.isWaiting, let why = a.waitingFor { add(why, .secondaryLabelColor) }
    return out
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// A menu bar app counts as frontmost often enough that, without this,
    /// macOS swallows the banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        openConductor()
        done()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Opening the menu never fetches; only the timer and "Refresh Now" spend a
        // request. This just applies any rebuild that was deferred while it was open.
        rebuildMenu()
    }
}

// `ClaudeUsage --dump` prints what the menu bar would show and exits. The status
// bar itself is invisible to screencapture, so this is how the data path is checked.
if CommandLine.arguments.contains("--agents") {
    let pins = PinStore()
    let snap = SessionScanner().snapshot(pinned: Array(pins.pins.values))
    if snap.sessions.isEmpty {
        print("No Claude Code sessions running")
    } else {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let memory = takeMemorySnapshot(sessions: snap.sessions)
        for a in snap.waiting + snap.busy + snap.idle {
            print(pad(String(a.pid), 7) + sessionRow(a, font: font, now: Date(), pin: pins.pins[a.sessionId],
                                                     memory: memory?.session(a.pid)?.bytes).string)
        }
        print("---")
        print("waiting=\(snap.waiting.count) busy=\(snap.busyCount) idle=\(snap.idle.count) subagents=\(snap.subagentCount)")
    }
    exit(0)
}

// `ClaudeUsage --memory` prints the memory readings behind the badge, the Memory
// row and the session rows.
if CommandLine.arguments.contains("--memory") {
    guard let m = takeMemorySnapshot(sessions: SessionScanner().snapshot().sessions) else {
        print("could not read the process table"); exit(1)
    }
    print("pressure \(m.pressure) · swap \(formatBytes(m.swapBytes)) · Claude \(formatBytes(m.claudeBytes))")
    for s in m.sessions.sorted(by: { $0.bytes > $1.bytes }) {
        print("  \(pad(String(s.pid), 7))\(pad(s.label, 36)) \(formatBytes(s.bytes))  (claude \(formatBytes(s.ownBytes)))")
        for c in s.commands.prefix(3) {
            print("    \(pad(String(c.root.pid), 7))\(pad(c.name, 20)) \(formatBytes(c.bytes))  \(c.procs.count) processes")
        }
    }
    print("largest apps: " + m.apps.map { "\($0.name) \(formatBytes($0.bytes))" }.joined(separator: ", "))
    exit(0)
}

// `ClaudeUsage --ping <pid> [--dry-run]` runs one keep-warm ping through the same
// path the app uses, or prints the command it would run.
if let i = CommandLine.arguments.firstIndex(of: "--ping") {
    let args = CommandLine.arguments
    guard i + 1 < args.count, let pid = pid_t(args[i + 1]),
          let a = SessionScanner().snapshot().sessions.first(where: { $0.pid == pid }) else {
        print("usage: --ping <pid of a live session>  (see --agents)"); exit(1)
    }
    if args.contains("--dry-run") {
        guard let launch = processLaunch(pid) else { print("cannot read process \(pid)"); exit(1) }
        print(([launch.exe] + pingArguments(from: Array(launch.args.dropFirst()), sessionId: a.sessionId))
            .map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }.joined(separator: " "))
        exit(0)
    }
    let context = a.contextTokens ?? 0
    switch runPing(a, pin: nil, live: []) {
    case .success(let r):
        print("read \(r.cacheRead) of last context \(context), write \(r.cacheWrite), input \(r.input)")
        exit(Double(r.cacheRead) >= pingMinCacheRead * Double(context) ? 0 : 2)
    case .failure(let e):
        print("ping failed: \(e)"); exit(1)
    }
}

if CommandLine.arguments.contains("--dump") {
    let sem = DispatchSemaphore(value: 0)
    var result: Usage?
    var err: String?
    if CommandLine.arguments.contains("--cache-only") {
        result = readCache()
        sem.signal()
    } else {
    fetchLive { r in
        switch r {
        case .success(let u): result = u
        case .failure(let e): err = "\(e)"; result = readCache()
        }
        sem.signal()
    }
    }
    _ = sem.wait(timeout: .now() + 20)
    if let e = err { print("live fetch failed: \(e)") }
    guard let u = result else { print("no usage available"); exit(1) }
    var barText = titleText(u)
    let snap = SessionScanner().snapshot()
    if let badge = memoryBadge(.current()) { barText = badge + "  " + barText }
    if let badge = waitingBadge(snap) { barText = badge + "  " + barText }
    if let suffix = agentSuffix(snap) { barText += "  " + suffix }
    print("menu bar: \(barText)")
    for w in u.windows {
        print(String(format: "  %@ %@ %3d%%   resets %@", pad(w.label, 12),
                     bar(w.utilization), Int(w.utilization.rounded()), countdown(to: w.resetsAt)))
    }
    if let e = u.extra, e.enabled {
        print(String(format: "  %@ %@ %3d%%   %.0f of %.0f %@", pad("Extra usage", 12),
                     bar(e.utilization), Int(e.utilization.rounded()), e.used, e.limit, e.currency))
    }
    print("  updated \(ago(u.fetchedAt)) · \(u.fromCache ? "cached" : "live")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
