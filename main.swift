// Claude Touch Bar
//
// Control Strip item (right end of the Touch Bar): the 5h rate-limit percentage, colored by state:
//   green = all sessions idle, orange = a session is running, red = 5h limit >= 90%.
//
// Tapping it opens the list view: rate limits, one cell per live Claude Code session,
// and the remote-control status pinned to the right end.
// Tapping a session brings its Terminal tab to the front and switches to that session's detail view.
// While a Terminal tab running Claude Code is frontmost, the bar follows it automatically.
// While an app listed in apps.txt (Safari, Chrome, ...) is frontmost, the list view replaces that app's Touch Bar.
//
// Designed to cost nothing when idle: no child processes, no network. It reads a few small JSON
// files and asks the kernel for process info, every 2s while the bar is visible or Terminal is
// in front, every 10s otherwise.
//
// Inputs:
//   ~/.claude/sessions/<pid>.json            written by Claude Code (pid, status, cwd, bridgeSessionId)
//   ~/.claude/cache/touchbar/<session>.json  written by statusline.sh (ctx, model, branch, cost, cache)
//   ~/.claude/cache/usage-latest.json        written by statusline.sh (rate limits)
//
// There is no public API for a system-wide Touch Bar, so this uses the private
// DFRFoundation / NSTouchBar calls. A macOS update may break it; see touchbar.log.

import AppKit

let home = NSHomeDirectory()
let sessionsDir = home + "/.claude/sessions"
let stateDir = home + "/.claude/cache/touchbar"
let usageFile = home + "/.claude/cache/usage-latest.json"
let logPath = home + "/.config/claude-touchbar/touchbar.log"
let appsFile = home + "/.config/claude-touchbar/apps.txt"

/// Bundle ids whose own Touch Bar gets replaced by the list view. One per line, # for comments.
func loadListApps() -> Set<String> {
    guard let text = try? String(contentsOfFile: appsFile, encoding: .utf8) else { return [] }
    let ids = text.split(separator: "\n")
        .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return Set(ids)
}

func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// ── formatting ──────────────────────────────────────────

/// 75 -> 1m, 4000 -> 1h06, 200000 -> 2d07h
func fmtDur(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return String(format: "%dh%02d", s / 3600, s % 3600 / 60) }
    return String(format: "%dd%02dh", s / 86400, s % 86400 / 3600)
}

/// 125219 -> 125k, 1000000 -> 1M
func fmtTok(_ n: Int) -> String {
    if n >= 1_000_000 { return "\(n / 1_000_000)M" }
    if n >= 1000 { return "\(n / 1000)k" }
    return "\(n)"
}

func truncate(_ s: String, _ max: Int) -> String {
    s.count > max ? String(s.prefix(max - 1)) + "…" : s
}

func truncateHead(_ s: String, _ max: Int) -> String {
    s.count > max ? "…" + String(s.suffix(max - 1)) : s
}

/// claude-fable-5-1 -> fable-5.1, claude-haiku-4-5-20251001 -> haiku-4.5
func shortModel(_ id: String) -> String {
    var m = id.hasPrefix("claude-") ? String(id.dropFirst(7)) : id
    if let r = m.range(of: "-[0-9]{8}$", options: .regularExpression) { m.removeSubrange(r) }
    if let r = m.range(of: "-[0-9]-[0-9]$", options: .regularExpression) {
        let tail = m[r].dropFirst().replacingOccurrences(of: "-", with: ".")
        m.replaceSubrange(r, with: "-" + tail)
    }
    return m
}

// ── process info straight from the kernel ───────────────

func kinfo(_ pid: pid_t) -> kinfo_proc? {
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
}

func ttyName(of pid: pid_t) -> String? {
    guard let dev = kinfo(pid)?.kp_eproc.e_tdev, dev != -1, let c = devname(dev, S_IFCHR) else { return nil }
    return String(cString: c)
}

func allProcs() -> [kinfo_proc] {
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    let count = size / stride + 32
    var buf = [kinfo_proc](repeating: kinfo_proc(), count: count)
    size = count * stride
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
    return Array(buf.prefix(size / stride))
}

func procArgs(_ pid: pid_t) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
    let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }   // executable path
    while i < size && buf[i] == 0 { i += 1 }   // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

struct ShellJob {
    let command: String
    let seconds: Int
}

/// Bash-tool commands show up as children of the claude process:
///   /bin/zsh -c source ~/.claude/shell-snapshots/... && eval '<command>' && pwd -P >| /tmp/...
func shellJobs(of pid: pid_t, in procs: [kinfo_proc], now: Int) -> [ShellJob] {
    var jobs: [ShellJob] = []
    for p in procs where p.kp_eproc.e_ppid == pid {
        let joined = procArgs(p.kp_proc.p_pid).joined(separator: " ")
        guard joined.contains("/shell-snapshots/"), let r = joined.range(of: "eval '") else { continue }
        var cmd = String(joined[r.upperBound...])
        for tail in ["' < /dev/null", "' && pwd -P"] {
            if let t = cmd.range(of: tail, options: .backwards) { cmd = String(cmd[..<t.lowerBound]) }
        }
        cmd = cmd.replacingOccurrences(of: "'\"'\"'", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
        jobs.append(ShellJob(command: cmd, seconds: now - Int(p.kp_proc.p_un.__p_starttime.tv_sec)))
    }
    return jobs.sorted { $0.seconds > $1.seconds }
}

// ── data model ──────────────────────────────────────────

func readJSON(_ path: String) -> [String: Any]? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

extension Dictionary where Key == String, Value == Any {
    func dict(_ k: String) -> [String: Any] { self[k] as? [String: Any] ?? [:] }
    func str(_ k: String) -> String { self[k] as? String ?? "" }
    func int(_ k: String) -> Int { (self[k] as? NSNumber)?.intValue ?? 0 }
    func dbl(_ k: String) -> Double { (self[k] as? NSNumber)?.doubleValue ?? 0 }
    func bool(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? false }
}

struct Session {
    let pid: Int
    let busy: Bool
    let since: Int              // epoch seconds of the last status change
    let cwd: String
    let bridge: String          // remote-control session id, empty when off
    let state: [String: Any]    // statusline snapshot, empty until that session has rendered once
    var shells: [ShellJob] = []

    var tty: String? { ttyName(of: pid_t(pid)) }
    var dir: String {
        let d = state.dict("workspace").str("current_dir")
        return d.isEmpty ? cwd : d
    }
    var name: String { dir == home ? "~" : (dir as NSString).lastPathComponent }
    var branch: String { state.str("tb_branch") }
    var title: String { state.str("session_name").replacingOccurrences(of: "\n", with: " ") }
    var ctx: Int? { state["tb_ctx_pct"] == nil ? nil : state.int("tb_ctx_pct") }
    var model: String { shortModel(state.dict("model").str("id")) }
}

struct Snapshot {
    var five: Int? = nil
    var fiveReset = 0
    var week = 0
    var weekReset = 0
    var sessions: [Session] = []
}

func loadSnapshot(withShells: Bool) -> Snapshot {
    let now = Int(Date().timeIntervalSince1970)
    var snap = Snapshot()

    if let u = readJSON(usageFile), u["five_pct"] != nil {
        snap.five = u.int("five_pct"); snap.fiveReset = u.int("five_reset")
        snap.week = u.int("week_pct"); snap.weekReset = u.int("week_reset")
        // past the reset time the window has rolled over
        if snap.fiveReset > 0 && now >= snap.fiveReset { snap.five = 0; snap.fiveReset = 0 }
        if snap.weekReset > 0 && now >= snap.weekReset { snap.week = 0; snap.weekReset = 0 }
    }

    let files = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir)) ?? []
    let procs = withShells ? allProcs() : []
    for f in files where f.hasSuffix(".json") {
        guard let j = readJSON(sessionsDir + "/" + f) else { continue }
        let pid = j.int("pid")
        guard pid > 0, kill(pid_t(pid), 0) == 0 else { continue }
        let sinceMs = j["statusUpdatedAt"] ?? j["updatedAt"] ?? j["startedAt"]
        var s = Session(
            pid: pid,
            busy: j.str("status") == "busy",
            since: ((sinceMs as? NSNumber)?.intValue ?? 0) / 1000,
            cwd: j.str("cwd"),
            bridge: j.str("bridgeSessionId"),
            state: readJSON(stateDir + "/" + j.str("sessionId") + ".json") ?? [:]
        )
        if withShells { s.shells = shellJobs(of: pid_t(pid), in: procs, now: now) }
        snap.sessions.append(s)
    }
    // busy sessions first, then most recently changed
    snap.sessions.sort { ($0.busy ? 0 : 1, -$0.since) < ($1.busy ? 0 : 1, -$1.since) }
    return snap
}

// ── view rows ───────────────────────────────────────────

struct Row: Equatable {
    var state = "-"     // busy | idle | hot | on | off | -
    var l1 = ""
    var l2 = ""
    var pid = 0         // > 0 makes the cell tappable
}

struct Render: Equatable {
    var trayText = "cc"
    var trayState = "idle"
    var usage = Row()
    var cells: [Row] = []
    var rc = Row()
}

func render(_ snap: Snapshot, mode: Mode) -> Render {
    let now = Int(Date().timeIntervalSince1970)
    var out = Render()

    if let five = snap.five {
        out.trayText = "\(five)%"
        out.usage.l1 = "5h \(five)%" + (snap.fiveReset > 0 ? " ↻ \(fmtDur(snap.fiveReset - now))" : "")
        out.usage.l2 = "7d \(snap.week)%" + (snap.weekReset > 0 ? " ↻ \(fmtDur(snap.weekReset - now))" : "")
    } else {
        out.usage.l1 = "5h --"; out.usage.l2 = "7d --"
    }
    if snap.sessions.contains(where: { $0.busy }) { out.trayState = "busy" }
    if (snap.five ?? 0) >= 90 { out.trayState = "hot" }

    switch mode {
    case .list:
        for s in snap.sessions {
            var l1 = truncate(s.name, 16)
            if !s.branch.isEmpty { l1 += " ⎇ \(s.branch)" }
            if !s.title.isEmpty { l1 += "  " + truncate(s.title, 22) }
            var l2 = (s.busy ? "RUN " : "IDLE ") + fmtDur(now - s.since)
            if let c = s.ctx { l2 += " · ctx \(c)%" }
            if !s.shells.isEmpty { l2 += " · sh×\(s.shells.count)" }
            if !s.bridge.isEmpty { l2 += " · RC" }
            out.cells.append(Row(state: s.busy ? "busy" : "idle", l1: l1, l2: l2, pid: s.pid))
        }
        if out.cells.isEmpty { out.cells = [Row(l1: "no sessions", l2: "claude is not running")] }
        let on = snap.sessions.filter { !$0.bridge.isEmpty }.count
        out.rc = on > 0
            ? Row(state: "on", l1: "remote-control", l2: "\(on)/\(snap.sessions.count) on")
            : Row(state: "off", l1: "remote-control", l2: "off")

    case .detail(let pid):
        guard let s = snap.sessions.first(where: { $0.pid == pid }) else {
            out.cells = [Row(l1: "session ended", l2: "pid \(pid)")]
            out.rc = Row(state: "off", l1: "remote-control", l2: "off")
            break
        }
        let path = s.dir.hasPrefix(home) ? "~" + s.dir.dropFirst(home.count) : s.dir
        out.cells.append(Row(state: s.busy ? "busy" : "idle", l1: truncateHead(path, 34),
                             l2: (s.busy ? "RUN " : "IDLE ") + fmtDur(now - s.since) + " · pid \(s.pid) · \(s.tty ?? "?")"))

        for job in s.shells {
            out.cells.append(Row(state: "busy", l1: "$ " + truncate(job.command, 36), l2: "shell · \(fmtDur(job.seconds))"))
        }

        if s.state.isEmpty {
            out.cells.append(Row(l1: "no statusline data yet", l2: "send a prompt in that session"))
        } else {
            let st = s.state
            if !s.branch.isEmpty {
                out.cells.append(Row(l1: "⎇ \(s.branch)", l2: s.title.isEmpty ? "untitled" : truncate(s.title, 30)))
            } else if !s.title.isEmpty {
                out.cells.append(Row(l1: truncate(s.title, 30), l2: "no git repo · /rename to change"))
            }

            let cw = st.dict("context_window"), cu = cw.dict("current_usage")
            let used = cu.int("input_tokens") + cu.int("cache_creation_input_tokens") + cu.int("cache_read_input_tokens")
            let ctx = s.ctx ?? 0
            out.cells.append(Row(state: ctx >= 80 ? "hot" : "-", l1: "ctx \(ctx)%",
                                 l2: "\(fmtTok(used)) / \(fmtTok(cw.int("context_window_size"))) tok"))

            out.cells.append(Row(l1: s.model, l2: "effort \(st.dict("effort").str("level")) · fast \(st.bool("fast_mode") ? "on" : "off") · think \(st.dict("thinking").bool("enabled") ? "on" : "off")"))

            let cost = st.dict("cost")
            out.cells.append(Row(l1: "+\(cost.int("total_lines_added")) −\(cost.int("total_lines_removed"))", l2: "lines changed"))
            out.cells.append(Row(l1: "up \(fmtDur(cost.int("total_duration_ms") / 1000))",
                                 l2: "api \(fmtDur(cost.int("total_api_duration_ms") / 1000)) · $\(String(format: "%.2f", cost.dbl("total_cost_usd")))"))

            let pc = st.dict("prompt_cache")
            let exp = pc.int("expires_at")
            out.cells.append(Row(state: exp > now ? "-" : "hot",
                                 l1: exp > now ? "cache warm \(fmtDur(exp - now))" : "cache cold",
                                 l2: "hit \(Int((pc.dbl("hit_ratio") * 100).rounded()))% · \(pc.int("requests")) req"))

            out.cells.append(Row(l1: "v" + st.str("version"), l2: String(st.str("session_id").prefix(8))))
        }

        out.rc = s.bridge.isEmpty
            ? Row(state: "off", l1: "remote-control", l2: "off")
            : Row(state: "on", l1: "remote-control", l2: "on · " + truncate(s.bridge, 17))
    }
    return out
}

// ── drawing ─────────────────────────────────────────────

func color(for state: String) -> NSColor? {
    switch state {
    case "busy": return .systemOrange
    case "hot": return .systemRed
    case "idle", "on": return .systemGreen
    case "off": return NSColor(white: 0.45, alpha: 1)
    default: return nil
    }
}

let line1Font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
let line2Font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
let dimColor = NSColor(white: 0.62, alpha: 1)

func twoLines(_ row: Row, alignment: NSTextAlignment = .left) -> NSAttributedString {
    let para = NSMutableParagraphStyle()
    para.maximumLineHeight = 13
    para.alignment = alignment
    let dot = color(for: row.state)
    let out = NSMutableAttributedString()
    if let dot = dot {
        out.append(NSAttributedString(string: "● ", attributes: [.font: line1Font, .foregroundColor: dot]))
    }
    out.append(NSAttributedString(string: row.l1, attributes: [.font: line1Font, .foregroundColor: NSColor.white]))
    let indent = (dot != nil && alignment == .left) ? "  " : ""
    out.append(NSAttributedString(string: "\n" + indent + row.l2, attributes: [.font: line2Font, .foregroundColor: dimColor]))
    out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
    return out
}

/// Two-line text cell. Tappable when `pid` is set.
final class Cell: NSTextField {
    var pid = 0
}

func makeCell() -> Cell {
    let f = Cell(labelWithString: "")
    f.maximumNumberOfLines = 2
    f.lineBreakMode = .byClipping
    f.setContentCompressionResistancePriority(.required, for: .horizontal)
    return f
}

extension NSTouchBarItem.Identifier {
    static let tray = NSTouchBarItem.Identifier("space.tabataba.claude-touchbar.tray")
    static let lead = NSTouchBarItem.Identifier("space.tabataba.claude-touchbar.lead")
    static let cells = NSTouchBarItem.Identifier("space.tabataba.claude-touchbar.cells")
    static let rc = NSTouchBarItem.Identifier("space.tabataba.claude-touchbar.rc")
}

enum Mode: Equatable {
    case list
    case detail(Int)
}

// ── Terminal.app via in-process AppleScript (needs the one-time Automation permission) ──

final class TerminalBridge {
    private let queue = DispatchQueue(label: "terminal-bridge")   // NSAppleScript is not thread-safe
    private var inFlight = false
    private var loggedError = false
    private lazy var frontScript = NSAppleScript(source: """
        tell application "Terminal"
            if (count of windows) is 0 then return ""
            return tty of selected tab of front window
        end tell
        """)

    /// tty of the front tab, e.g. "ttys004". Skips the call while one is pending (permission prompt).
    func frontTTY(_ done: @escaping (String?) -> Void) {
        guard !inFlight else { return }
        inFlight = true
        queue.async {
            var err: NSDictionary?
            let r = self.frontScript?.executeAndReturnError(&err)
            if let err = err, !self.loggedError {
                self.loggedError = true
                log("Terminal automation failed: \(err[NSAppleScript.errorMessage] ?? err)")
            }
            let tty = r?.stringValue.map { $0.replacingOccurrences(of: "/dev/", with: "") }
            DispatchQueue.main.async {
                self.inFlight = false
                done((tty ?? "").isEmpty ? nil : tty)
            }
        }
    }

    func focus(tty: String) {
        guard tty.range(of: "^ttys[0-9]+$", options: .regularExpression) != nil else { return }
        queue.async {
            let script = NSAppleScript(source: """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "/dev/\(tty)" then
                                if miniaturized of w then set miniaturized of w to false
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end tell
                """)
            var err: NSDictionary?
            script?.executeAndReturnError(&err)
            if let err = err { log("focus failed: \(err[NSAppleScript.errorMessage] ?? err)") }
        }
    }
}

// ── app ─────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    var trayItem: NSCustomTouchBarItem!
    var trayButton: NSButton!
    let usageCell = makeCell()
    var backButton: NSButton!
    let leadStack = NSStackView()
    let cellStack = NSStackView()
    let rcCell = makeCell()
    var bar: NSTouchBar!
    var visibleObservation: NSKeyValueObservation?
    let terminal = TerminalBridge()

    var mode: Mode = .list
    var last = Render()
    var ticks = 0
    var sessionTTYs: [String: Int] = [:]   // tty -> claude pid, from the latest snapshot

    // What the frontmost app calls for: a session's detail (Terminal tab running Claude),
    // the list (apps in apps.txt), or nothing. `key` tells two list apps apart.
    struct AutoTarget: Equatable {
        let mode: Mode
        let key: String
    }
    var autoTarget: AutoTarget? = nil
    var autoPresented = false
    var listApps = loadListApps()

    var terminalIsFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal"
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // The Control Strip clips wide items, so the tray shows the 5h percentage only.
        trayButton = NSButton(title: "cc", target: self, action: #selector(toggleBar))
        trayButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        trayItem = NSCustomTouchBarItem(identifier: .tray)
        trayItem.view = trayButton

        backButton = NSButton(title: "‹ all", target: self, action: #selector(backToList))
        backButton.font = line1Font
        backButton.isHidden = true
        leadStack.orientation = .horizontal
        leadStack.spacing = 8
        leadStack.addArrangedSubview(backButton)
        leadStack.addArrangedSubview(usageCell)

        cellStack.orientation = .horizontal
        cellStack.spacing = 22
        cellStack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        rcCell.setContentHuggingPriority(.required, for: .horizontal)

        bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.lead, .cells, .rc]

        installTray()
        refresh()

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)

        visibleObservation = bar.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            if change.newValue == false {
                self?.autoPresented = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.installTray() }
            }
        }

        // The Control Strip silently drops registrations, so re-assert on every plausible trigger.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.installTray() }
            }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == "com.apple.controlstrip" {
                log("ControlStrip relaunched, reinstalling tray item")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.installTray() }
            }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPresence(true)
            self?.listApps = loadListApps()   // picks up edits to apps.txt without a rebuild
            self?.checkFront()
        }
        checkFront()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        switch id {
        case .lead:
            item.view = leadStack
        case .cells:
            // no intrinsic width, so the bar stretches it and pushes .rc to the right end
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasHorizontalScroller = false
            scroll.documentView = cellStack
            cellStack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                cellStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                cellStack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
                cellStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            ])
            item.view = scroll
        case .rc:
            item.view = rcCell
        default:
            return nil
        }
        return item
    }

    // ── private API ─────────────────────────────────────
    lazy var setPresenceFn: (@convention(c) (NSString, Bool) -> Void)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY),
              let sym = dlsym(h, "DFRElementSetControlStripPresenceForIdentifier") else {
            log("DFRElementSetControlStripPresenceForIdentifier not found")
            return nil
        }
        return unsafeBitCast(sym, to: (@convention(c) (NSString, Bool) -> Void).self)
    }()

    func setPresence(_ on: Bool) {
        setPresenceFn?(NSTouchBarItem.Identifier.tray.rawValue as NSString, on)
    }

    func installTray() {
        let remove = NSSelectorFromString("removeSystemTrayItem:")
        let add = NSSelectorFromString("addSystemTrayItem:")
        guard NSTouchBarItem.responds(to: add) else { log("addSystemTrayItem: not found"); return }
        setPresence(false)
        if NSTouchBarItem.responds(to: remove) { NSTouchBarItem.perform(remove, with: trayItem) }
        NSTouchBarItem.perform(add, with: trayItem)
        setPresence(true)
    }

    func present() {
        let sel3 = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        let sel2 = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        if let m = class_getClassMethod(NSTouchBar.self, sel3) {
            typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBar, Int, NSString) -> Void
            let fn = unsafeBitCast(method_getImplementation(m), to: Fn.self)
            fn(NSTouchBar.self, sel3, bar, 0, NSTouchBarItem.Identifier.tray.rawValue as NSString)
        } else if NSTouchBar.responds(to: sel2) {
            NSTouchBar.perform(sel2, with: bar, with: NSTouchBarItem.Identifier.tray.rawValue as NSString)
        } else {
            log("presentSystemModalTouchBar not found")
        }
    }

    func dismiss() {
        let sel = NSSelectorFromString("dismissSystemModalTouchBar:")
        if NSTouchBar.responds(to: sel) { NSTouchBar.perform(sel, with: bar) }
        autoPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.installTray() }
    }

    // ── actions ─────────────────────────────────────────
    @objc func toggleBar() {
        if bar.isVisible {
            dismiss()
        } else {
            mode = autoTarget?.mode ?? .list
            present()
            refresh(forceShells: true)
        }
    }

    @objc func backToList() {
        setMode(.list)
    }

    @objc func cellTapped(_ g: NSGestureRecognizer) {
        guard let cell = g.view as? Cell, cell.pid > 0 else { return }
        setMode(.detail(cell.pid))
        if let tty = ttyName(of: pid_t(cell.pid)) { terminal.focus(tty: tty) }
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        refresh()
    }

    // ── follow the frontmost app ────────────────────────
    func checkFront() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if front == "com.apple.Terminal" {
            terminal.frontTTY { [weak self] tty in
                guard let self = self, self.terminalIsFront else { return }
                let pid = tty.flatMap { self.sessionTTYs[$0] }
                self.autoTargetChanged(to: pid.map { AutoTarget(mode: .detail($0), key: "pid \($0)") })
            }
        } else if listApps.contains(front) {
            autoTargetChanged(to: AutoTarget(mode: .list, key: front))
        } else {
            autoTargetChanged(to: nil)
        }
    }

    /// Acts only on changes, so closing the bar or going back to the list sticks until the app or tab changes.
    func autoTargetChanged(to target: AutoTarget?) {
        guard target != autoTarget else { return }
        autoTarget = target
        log("auto -> \(target?.key ?? "none")")
        if let target = target {
            setMode(target.mode)
            if !bar.isVisible {
                present()
                autoPresented = true
                refresh(forceShells: true)
            }
        } else if autoPresented && bar.isVisible {
            dismiss()
            setMode(.list)
        }
    }

    // ── refresh ─────────────────────────────────────────
    func tick() {
        ticks += 1
        let active = bar.isVisible || terminalIsFront
        guard active || ticks % 5 == 0 else { return }   // idle: every 10s

        if terminalIsFront { checkFront() }
        refresh()
        if !bar.isVisible {
            // keep the Control Strip registration alive; fully reinstall once a minute
            if ticks % 30 == 0 { installTray() } else { setPresence(true) }
        }
    }

    func refresh(forceShells: Bool = false) {
        let m = mode
        let visible = forceShells || bar.isVisible
        DispatchQueue.global(qos: .utility).async {
            // the process table is only scanned while someone is looking
            let snap = loadSnapshot(withShells: visible)
            var ttys: [String: Int] = [:]
            for s in snap.sessions { if let t = s.tty { ttys[t] = s.pid } }
            let r = render(snap, mode: m)
            DispatchQueue.main.async {
                self.sessionTTYs = ttys
                guard m == self.mode else { return }
                self.apply(r)
            }
        }
    }

    func apply(_ r: Render) {
        let isDetail = mode != .list
        backButton.isHidden = !isDetail
        usageCell.isHidden = isDetail

        if r.trayText != last.trayText || r.trayState != last.trayState || trayButton.title == "cc" {
            trayButton.attributedTitle = NSAttributedString(string: r.trayText, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: color(for: r.trayState) ?? .white,
            ])
        }
        if r.usage != last.usage { usageCell.attributedStringValue = twoLines(r.usage) }
        if r.rc != last.rc { rcCell.attributedStringValue = twoLines(r.rc, alignment: .right) }

        if r.cells != last.cells {
            // reuse views so a refresh never interrupts a touch or resets the scroll position
            while cellStack.arrangedSubviews.count < r.cells.count {
                let c = makeCell()
                let tap = NSClickGestureRecognizer(target: self, action: #selector(cellTapped(_:)))
                tap.allowedTouchTypes = .direct
                c.addGestureRecognizer(tap)
                cellStack.addArrangedSubview(c)
            }
            while cellStack.arrangedSubviews.count > r.cells.count {
                let v = cellStack.arrangedSubviews.last!
                cellStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            for (i, row) in r.cells.enumerated() {
                let c = cellStack.arrangedSubviews[i] as! Cell
                c.pid = row.pid
                c.attributedStringValue = twoLines(row)
            }
        }
        last = r
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
log("started")
app.run()
