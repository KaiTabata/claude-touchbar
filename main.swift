// Claude Touch Bar
//
// Control Strip item (right end of the Touch Bar): the 5h rate-limit percentage, colored by state:
//   green = all sessions idle, orange = a session is running, red = 5h limit >= 90%.
//
// Tapping it opens the list view: rate limits, one cell per live Claude Code session,
// and the remote-control status pinned to the right end.
// Tapping a session brings its Terminal tab to the front and switches to that session's detail view.
// Tapping a detail cell explains it (in Japanese) and offers related slash commands, which are typed
// into that session's Terminal tab.
// While a Terminal tab running Claude Code is frontmost, the bar follows it automatically.
// While an app listed in apps.txt (Safari, Chrome, Finder, ...) is frontmost, the list view replaces that app's Touch Bar.
// While any session has remote-control on, system sleep is disabled (lid closed included) so the
// session stays reachable; a teal dot / "awake" marks it. Needs the sudoers rule from install-awake.sh.
// "allow sleep" in the remote-control cell's info view relaxes that to idle sleep only (closing the lid
// sleeps) until the power adapter is plugged in again; "sleep" marks it.
// "all on" / "all off" in the same view switch remote-control for every session at once.
// The mic button starts Claude Code's own voice dictation (/voice tap) in the session's Terminal tab:
// tap to talk, tap again to send, ✕ to discard. It presses Space / Esc there, which needs the
// Accessibility permission.
//
// Designed to cost nothing when idle: no network, and no child processes except one `pmset` call
// when keep-awake flips. It reads a few small JSON files and asks the kernel for process info,
// every 2s while the bar is visible or Terminal is in front, every 10s otherwise.
//
// Inputs:
//   ~/.claude/sessions/<pid>.json            written by Claude Code (pid, status, cwd, bridgeSessionId)
//   ~/.claude/cache/touchbar/<session>.json  written by statusline.sh (ctx, model, branch, cost, cache)
//   ~/.claude/cache/usage-latest.json        written by statusline.sh (rate limits)
//
// There is no public API for a system-wide Touch Bar, so this uses the private
// DFRFoundation / NSTouchBar calls. A macOS update may break it; see touchbar.log.

import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

let home = NSHomeDirectory()
let sessionsDir = home + "/.claude/sessions"
let stateDir = home + "/.claude/cache/touchbar"
let usageFile = home + "/.claude/cache/usage-latest.json"
// Optional: the voice-call bot (a Discord bot that talks to Claude Code). The cell only shows when its LaunchAgent exists.
let callLabel = "com.kaitabata.claude-call"
let callPlist = home + "/Library/LaunchAgents/" + callLabel + ".plist"
let callStatusFile = home + "/Developer/claude-call/status.json"
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

// ── keep awake while remote-control is on ───────────────

/// `pmset disablesleep`, as the kernel sees it. Unlike a power assertion it also survives closing the lid.
func sleepDisabled() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    let v = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    return (v as? Bool) ?? false
}

/// Whether the power adapter is connected, and the battery level when it is not.
func powerState() -> (onAC: Bool, battery: Int?) {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    guard (IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String) == kIOPMBatteryPowerKey else { return (true, nil) }
    for ps in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
        if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
           let pct = d[kIOPSCurrentCapacityKey] as? Int {
            return (false, pct)
        }
    }
    return (false, nil)
}

/// Disables system sleep while some session has remote-control on, and owns that setting outright:
/// with no remote-control session it is switched back off, whoever set it, because a leftover
/// `disablesleep 1` means a laptop that stays awake in a bag. The setting needs root, so it goes through
/// `sudo -n pmset` (see install-awake.sh); that is the only child process this app starts, and only
/// when the state flips.
///
/// "allow sleep" trades that for a power assertion against idle sleep, which closing the lid still
/// overrides, to save the battery. It lasts until the power adapter is plugged in again.
final class KeepAwake {
    private let lock = NSLock()
    private var inFlight = false
    private var failed = false
    private var quitting = false
    private var retryAt = Date.distantPast
    private var allowSleep_ = false
    private var wasOnAC = true
    private var idleAssertion: IOPMAssertionID = 0
    var onChange: (() -> Void)?

    var allowSleep: Bool { lock.lock(); defer { lock.unlock() }; return allowSleep_ }

    func toggleAllowSleep() {
        lock.lock(); allowSleep_.toggle(); let on = allowSleep_; lock.unlock()
        log("allow sleep \(on ? "on" : "off")")
    }

    /// Returns what the remote-control cell shows: "awake", "sleep" (allow sleep), "batt" (low battery), "sudo✗" or "".
    func update(rcOn: Bool) -> String {
        lock.lock(); defer { lock.unlock() }
        guard !quitting else { return "" }
        let power = powerState()
        if power.onAC && !wasOnAC && allowSleep_ {
            allowSleep_ = false
            log("allow sleep off (power adapter connected)")
        }
        wasOnAC = power.onAC
        let low = rcOn && (power.battery ?? 100) <= 15   // not worth draining a closed laptop to zero
        let want = rcOn && !low && !allowSleep_
        let actual = sleepDisabled()
        if want != actual { set(want) }
        holdIdle(rcOn && !low && allowSleep_)
        if actual { return "awake" }
        if low { return "batt" }
        if rcOn && allowSleep_ { return "sleep" }
        return want && failed ? "sudo✗" : ""
    }

    private func holdIdle(_ on: Bool) {
        if on && idleAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Claude Code remote-control" as CFString, &idleAssertion)
        } else if !on && idleAssertion != 0 {
            IOPMAssertionRelease(idleAssertion)
            idleAssertion = 0
        }
    }

    private func set(_ on: Bool) {
        guard !inFlight, Date() >= retryAt else { return }
        inFlight = true
        DispatchQueue.global(qos: .utility).async {
            let ok = KeepAwake.pmset(on)
            self.lock.lock()
            self.inFlight = false
            if ok {
                log("keep-awake \(on ? "on" : "off")")
            } else if !self.failed {
                log("keep-awake: sudo pmset failed; run ./install-awake.sh")
            }
            self.failed = !ok
            self.retryAt = ok ? .distantPast : Date().addingTimeInterval(60)
            self.lock.unlock()
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    static func pmset(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// On quit (launchd sends SIGTERM): `disablesleep` persists across reboots, so never leave it behind.
    func restoreForExit() {
        lock.lock(); quitting = true; lock.unlock()   // a refresh racing with the exit must not turn it back on
        for _ in 0..<30 {
            lock.lock(); let busy = inFlight; lock.unlock()
            if !busy { break }
            usleep(100_000)
        }
        if sleepDisabled() { log("keep-awake off (quit)\(KeepAwake.pmset(false) ? "" : " failed")") }
    }
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
    let userName: String        // set by /rename or `claude -n`; written to the session file immediately
    let state: [String: Any]    // statusline snapshot, empty until that session has rendered once
    var shells: [ShellJob] = []

    var tty: String? { ttyName(of: pid_t(pid)) }
    var dir: String {
        let d = state.dict("workspace").str("current_dir")
        return d.isEmpty ? cwd : d
    }
    var name: String { dir == home ? "~" : (dir as NSString).lastPathComponent }
    var branch: String { state.str("tb_branch") }
    /// The statusline snapshot only refreshes when that session renders, so a /rename shows up late there.
    var title: String {
        let t = userName.isEmpty ? state.str("session_name") : userName
        return t.replacingOccurrences(of: "\n", with: " ")
    }
    var ctx: Int? { state["tb_ctx_pct"] == nil ? nil : state.int("tb_ctx_pct") }
    var model: String { shortModel(state.dict("model").str("id")) }
}

struct Snapshot {
    var five: Int? = nil
    var fiveReset = 0
    var week = 0
    var weekReset = 0
    var sessions: [Session] = []
    var awake = ""              // KeepAwake.update's label
    var allowSleep = false
    var call = ""               // voice-call bot: "" (not installed) | off | on | talk | work
}

/// The bot writes its pid and state to a small file; a dead pid means it is off.
func callState() -> String {
    guard FileManager.default.fileExists(atPath: callPlist) else { return "" }
    guard let j = readJSON(callStatusFile), j.int("pid") > 0, kill(pid_t(j.int("pid")), 0) == 0 else { return "off" }
    return j.bool("inCall") ? "talk" : j.int("bg") > 0 ? "work" : "on"
}

/// Turning it off also disables the LaunchAgent, so it stays off across logins.
func setCall(on: Bool) {
    let target = "gui/\(getuid())/" + callLabel
    let steps = on ? [["enable", target], ["bootstrap", "gui/\(getuid())", callPlist]]
                   : [["disable", target], ["bootout", target]]
    for args in steps {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { log("launchctl \(args[0]) failed: \(error)") }
    }
    log("call \(on ? "on" : "off")")
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
            userName: j.str("nameSource") == "user" ? j.str("name") : "",
            state: readJSON(stateDir + "/" + j.str("sessionId") + ".json") ?? [:]
        )
        if withShells { s.shells = shellJobs(of: pid_t(pid), in: procs, now: now) }
        snap.sessions.append(s)
    }
    // busy sessions first, then most recently changed
    snap.sessions.sort { ($0.busy ? 0 : 1, -$0.since) < ($1.busy ? 0 : 1, -$1.since) }
    snap.call = callState()
    return snap
}

// ── view rows ───────────────────────────────────────────

struct Row: Equatable {
    var state = "-"     // busy | idle | hot | on | off | -
    var l1 = ""
    var l2 = ""
    var pid = 0         // > 0: tapping opens that session (list view)
    var key = ""        // non-empty: tapping opens the explanation for this cell (detail view)
    var tail = ""       // keep-awake note after l2: teal for "awake", red for a problem
}

/// A slash command offered in the info view. `confirm` asks for a second tap.
/// `local` actions are handled by this app instead of being typed into the session.
struct Action: Equatable {
    let command: String
    var label = ""      // button title; the command itself when empty
    var confirm = false
    var local = false
    var title: String { label.isEmpty ? command : label }
}

struct Render: Equatable {
    var trayText = "cc"
    var trayState = "idle"
    var trayAwake = false
    var usage = Row()
    var cells: [Row] = []
    var actions: [Action] = []
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
    out.usage.key = "usage"
    if snap.sessions.contains(where: { $0.busy }) { out.trayState = "busy" }
    if (snap.five ?? 0) >= 90 { out.trayState = "hot" }
    out.trayAwake = snap.awake == "awake"
    let rcOn = snap.sessions.filter { !$0.bridge.isEmpty }.count
    let callRow: Row? = snap.call.isEmpty ? nil : Row(
        state: snap.call == "off" ? "off" : snap.call == "on" ? "on" : "busy", l1: "call",
        l2: ["off": "off", "on": "on · standby", "talk": "on · in call", "work": "on · working"][snap.call] ?? snap.call, key: "call")

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
        if let c = callRow { out.cells.append(c) }
        out.rc = rcOn > 0
            ? Row(state: "on", l1: "remote-control", l2: "\(rcOn)/\(snap.sessions.count) on")
            : Row(state: "off", l1: "remote-control", l2: "off")

    case .detail(let pid):
        guard let s = snap.sessions.first(where: { $0.pid == pid }) else {
            out.cells = [Row(l1: "session ended", l2: "pid \(pid)")]
            out.rc = rcOn > 0
                ? Row(state: "held", l1: "remote-control", l2: "+\(rcOn)")
                : Row(state: "off", l1: "remote-control", l2: "off")
            break
        }
        let path = s.dir.hasPrefix(home) ? "~" + s.dir.dropFirst(home.count) : s.dir
        out.cells.append(Row(state: s.busy ? "busy" : "idle", l1: truncateHead(path, 34),
                             l2: (s.busy ? "RUN " : "IDLE ") + fmtDur(now - s.since) + " · pid \(s.pid) · \(s.tty ?? "?")", key: "path"))

        for (i, job) in s.shells.enumerated() {
            out.cells.append(Row(state: "busy", l1: "$ " + truncate(job.command, 36), l2: "shell · \(fmtDur(job.seconds))", key: "shell\(i)"))
        }

        if s.state.isEmpty {
            out.cells.append(Row(l1: "no statusline data yet", l2: "send a prompt in that session", key: "nostate"))
        } else {
            let st = s.state
            if !s.branch.isEmpty {
                out.cells.append(Row(l1: "⎇ \(s.branch)", l2: s.title.isEmpty ? "untitled" : truncate(s.title, 30), key: "branch"))
            } else if !s.title.isEmpty {
                out.cells.append(Row(l1: truncate(s.title, 30), l2: "no git repo · /rename to change", key: "branch"))
            }

            let cw = st.dict("context_window"), cu = cw.dict("current_usage")
            let used = cu.int("input_tokens") + cu.int("cache_creation_input_tokens") + cu.int("cache_read_input_tokens")
            let ctx = s.ctx ?? 0
            out.cells.append(Row(state: ctx >= 80 ? "hot" : "-", l1: "ctx \(ctx)%",
                                 l2: "\(fmtTok(used)) / \(fmtTok(cw.int("context_window_size"))) tok", key: "ctx"))

            out.cells.append(Row(l1: s.model, l2: "effort \(st.dict("effort").str("level")) · fast \(st.bool("fast_mode") ? "on" : "off") · think \(st.dict("thinking").bool("enabled") ? "on" : "off")", key: "model"))

            let cost = st.dict("cost")
            out.cells.append(Row(l1: "+\(cost.int("total_lines_added")) −\(cost.int("total_lines_removed"))", l2: "lines changed", key: "lines"))
            out.cells.append(Row(l1: "up \(fmtDur(cost.int("total_duration_ms") / 1000))",
                                 l2: "api \(fmtDur(cost.int("total_api_duration_ms") / 1000)) · $\(String(format: "%.2f", cost.dbl("total_cost_usd")))", key: "cost"))

            let pc = st.dict("prompt_cache")
            let exp = pc.int("expires_at")
            out.cells.append(Row(state: exp > now ? "-" : "hot",
                                 l1: exp > now ? "cache warm \(fmtDur(exp - now))" : "cache cold",
                                 l2: "hit \(Int((pc.dbl("hit_ratio") * 100).rounded()))% · \(pc.int("requests")) req", key: "cache"))

            out.cells.append(Row(l1: "v" + st.str("version"), l2: String(st.str("session_id").prefix(8)), key: "version"))
        }
        if let c = callRow { out.cells.append(c) }

        // l2 plus the keep-awake tail has to stay within the width of "● remote-control" (17 chars at this size).
        // "off · +1": off here, but another session's remote-control still keeps the Mac awake
        if !s.bridge.isEmpty {
            out.rc = Row(state: "on", l1: "remote-control", l2: snap.awake.isEmpty ? "on · " + truncate(s.bridge, 12) : "on")
        } else if rcOn > 0 {
            out.rc = Row(state: "held", l1: "remote-control", l2: "off · +\(rcOn)")
        } else {
            out.rc = Row(state: "off", l1: "remote-control", l2: "off")
        }

    case .info(let pid, let key):
        let base = render(snap, mode: pid > 0 ? .detail(pid) : .list)
        out.rc = base.rc
        let session = snap.sessions.first { $0.pid == pid }
        let shellIndex = key.hasPrefix("shell") ? Int(key.dropFirst(5)) : nil
        let job = shellIndex.flatMap { i in session.flatMap { i < $0.shells.count ? $0.shells[i] : nil } }
        let help = helpText(for: key, shell: job)

        var live: Row? = key == "usage" ? base.usage : key == "rc" ? base.rc : base.cells.first { $0.key == key }
        live?.key = ""
        if let live = live { out.cells.append(live) }
        out.cells.append(Row(state: "jp", l1: help.l1, l2: help.l2))
        out.actions = session == nil ? [] : help.actions
        if key == "rc" {
            if rcOn < snap.sessions.count { out.actions.append(Action(command: "rc-all-on", label: "all on", local: true)) }
            if rcOn > 0 { out.actions.append(Action(command: "rc-all-off", label: "all off", local: true)) }
            out.actions.append(Action(command: "allow-sleep", label: snap.allowSleep ? "keep awake" : "allow sleep", local: true))
        }
        if key == "call" && !snap.call.isEmpty {
            out.actions = [Action(command: snap.call == "off" ? "call-on" : "call-off", label: snap.call == "off" ? "turn on" : "turn off", local: true)]
        }
    }
    out.rc.key = "rc"
    if case .info = mode {} else if !snap.awake.isEmpty { out.rc.tail = " · " + snap.awake }
    return out
}

// ── explanations shown when a detail cell is tapped ─────

struct Help {
    let l1: String
    let l2: String
    var actions: [Action] = []
}

func helpText(for key: String, shell: ShellJob?) -> Help {
    if key.hasPrefix("shell") {
        return Help(l1: "$ " + truncate(shell?.command ?? "（終了しました）", 70),
                    l2: "Claude が Bash ツールで実行中のコマンドです。長く動いているものは、バックグラウンド実行か終了待ちのループです。")
    }
    switch key {
    case "path":
        return Help(l1: "作業ディレクトリです。Claude はここを基準にファイルを読み書きします。",
                    l2: "RUN=応答を生成中 / IDLE=入力待ち。pid と tty はこのセッションのプロセス番号と端末です。",
                    actions: [Action(command: "/status")])
    case "branch":
        return Help(l1: "⎇ は git ブランチです。* は未コミットの変更があることを示します。",
                    l2: "もう一方はセッション名です。ターミナルで「/rename 新しい名前」と入力すると変更できます。")
    case "ctx":
        return Help(l1: "コンテキスト使用量です。会話・読んだファイル・ツール結果の合計で、80% を超えると赤くなります。",
                    l2: "上限に近づくと自動で要約されます。/context で内訳を表示、/compact で今すぐ要約します。",
                    actions: [Action(command: "/context"), Action(command: "/compact", confirm: true)])
    case "model":
        return Help(l1: "使用中のモデルです。effort=考える深さ / fast=高速出力モード / think=拡張思考。",
                    l2: "/model でモデルを選び直し、/fast で高速モードを切り替え、/config で設定全般を開きます。",
                    actions: [Action(command: "/model"), Action(command: "/fast"), Action(command: "/config")])
    case "lines":
        return Help(l1: "このセッションで Claude が追加した行数（+）と削除した行数（−）です。",
                    l2: "セッション開始からの累計です。")
    case "cost":
        return Help(l1: "up=セッション開始からの経過時間 / api=API の応答を待っていた時間の合計です。",
                    l2: "$ は API 料金に換算した目安で、サブスクリプションでは実際の請求額ではありません。/usage で枠の使用状況を確認できます。",
                    actions: [Action(command: "/usage")])
    case "cache":
        return Help(l1: "プロンプトキャッシュです。warm の間は会話の読み直しが安く速く済みます。hit はキャッシュ命中率です。",
                    l2: "残り時間が切れて cold になると、次の発言で会話全体を読み直すため、使用量を多めに消費します。")
    case "version":
        return Help(l1: "Claude Code のバージョンと、セッション ID の先頭 8 桁です。",
                    l2: "「claude -r」でこの会話を後から再開できます。/status でバージョンやアカウントの状態を確認できます。",
                    actions: [Action(command: "/status")])
    case "usage":
        return Help(l1: "5h=5 時間枠 / 7d=週間枠の使用率です。↻ はリセットまでの残り時間です。",
                    l2: "5h が 90% 以上になると Control Strip の数字が赤くなります。/usage で詳しい内訳を確認できます。",
                    actions: [Action(command: "/usage")])
    case "rc":
        return Help(l1: "Remote Control です。on のセッションは claude.ai やスマホアプリから続きを操作できます。all on / all off で全セッションをまとめて切り替えます。",
                    l2: "on の間は蓋を閉じても寝ません（awake）。allow sleep で蓋を閉じたら寝るように（sleep）、電源をつなぐと元に戻ります。電池 15% 以下では解除。「off · +1」は他の 1 セッションが on。",
                    actions: [Action(command: "/remote-control")])
    case "call":
        return Help(l1: "Claude通話です。on の間、iPhone の Discord でサーバー「Claude通話」のボイスチャンネルに入ると、Mac の Claude Code と声で話せます。",
                    l2: "standby=待機中 / in call=通話中 / working=頼まれた作業を裏で実行中。turn off で完全に止まり、次にログインしても off のままです。")
    case "nostate":
        return Help(l1: "このセッションはまだ statusline のデータを書き出していません。",
                    l2: "そのセッションで一度メッセージを送ると、コンテキストやモデルなどが表示されます。")
    default:
        return Help(l1: "", l2: "")
    }
}

// ── drawing ─────────────────────────────────────────────

func color(for state: String) -> NSColor? {
    switch state {
    case "busy": return .systemOrange
    case "hot": return .systemRed
    case "idle", "on": return .systemGreen
    case "held": return awakeColor
    case "off": return NSColor(white: 0.45, alpha: 1)
    default: return nil
    }
}

let line1Font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
let line2Font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
let dimColor = NSColor(white: 0.62, alpha: 1)
let awakeColor = NSColor.systemTeal

func twoLines(_ row: Row, alignment: NSTextAlignment = .left) -> NSAttributedString {
    let para = NSMutableParagraphStyle()
    para.maximumLineHeight = 13
    para.alignment = alignment
    if row.state == "jp" {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.88, alpha: 1), .paragraphStyle: para]
        return NSAttributedString(string: row.l1 + "\n" + row.l2, attributes: attrs)
    }
    let dot = color(for: row.state)
    let out = NSMutableAttributedString()
    if let dot = dot {
        out.append(NSAttributedString(string: "● ", attributes: [.font: line1Font, .foregroundColor: dot]))
    }
    out.append(NSAttributedString(string: row.l1, attributes: [.font: line1Font, .foregroundColor: NSColor.white]))
    let indent = (dot != nil && alignment == .left) ? "  " : ""
    out.append(NSAttributedString(string: "\n" + indent + row.l2, attributes: [.font: line2Font, .foregroundColor: dimColor]))
    if !row.tail.isEmpty {
        let tint = row.tail.hasSuffix("awake") ? awakeColor : row.tail.hasSuffix("sleep") ? dimColor : NSColor.systemRed
        out.append(NSAttributedString(string: row.tail, attributes: [.font: line2Font, .foregroundColor: tint]))
    }
    out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
    return out
}

/// Two-line text cell. Tappable when `pid` is set.
final class Cell: NSTextField {
    var pid = 0
    var key = ""
}

final class ActionButton: NSButton {
    var action_: Action?
    var armed = false
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
    static let actions = NSTouchBarItem.Identifier("space.tabataba.claude-touchbar.actions")
    static let rc = NSTouchBarItem.Identifier("space.tabataba.claude-touchbar.rc")
}

enum Mode: Equatable {
    case list
    case detail(Int)
    case info(Int, String)   // pid (0 = no session) and the Row.key being explained
}

// ── what a Claude Code tab is showing ───────────────────

/// The visible text of a Terminal tab running Claude Code, read through AppleScript.
/// It is plain text, so a suggested prompt and a half-typed one look the same.
struct TermScreen {
    let tail: [String]   // the bottom of the screen, blank lines dropped

    init(_ text: String) {
        tail = Array(text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(16))
    }

    func contains(_ s: String) -> Bool { tail.contains { $0.contains(s) } }

    /// Claude Code's indicator while dictation is recording in "tap" mode.
    var recording: Bool { contains("REC · tap to send") }

    /// The prompt box is on screen: "❯" between two rules, just above the status lines.
    /// A permission prompt or a menu replaces it, and keys typed then would answer that instead.
    /// A named session carries its name inside the upper rule ("──── name ─"), so a rule is a line
    /// that starts with a long run of "─", not one made of nothing else.
    var hasPrompt: Bool {
        let rules = tail.indices.filter { i in
            tail[i].trimmingCharacters(in: .whitespaces).prefix { $0 == "─" }.count >= 20
        }
        guard rules.count >= 2 else { return false }
        let top = rules[rules.count - 2], bottom = rules[rules.count - 1]
        return bottom > top + 1 && bottom >= tail.count - 8 && tail[top + 1].hasPrefix("❯")
    }
}

/// Dictation needs `/voice tap`: in the default hold mode a single Space press only types a space.
func voiceTapEnabled() -> Bool {
    guard let v = readJSON(home + "/.claude/settings.json")?.dict("voice") else { return false }
    return v.bool("enabled") && v.str("mode") == "tap"
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

    private func run(_ source: String) -> (value: String?, error: String?) {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return (r?.stringValue, err.map { "\($0[NSAppleScript.errorMessage] ?? $0)" })
    }

    private func valid(_ tty: String) -> Bool {
        tty.range(of: "^ttys[0-9]+$", options: .regularExpression) != nil
    }

    /// AppleScript that runs `body` for the tab on this tty, as `tab ti of window wi`. Returns "" when there is none.
    /// (Index-based on purpose: with `repeat with t in tabs`, `contents of t` yields the reference, not the text.)
    private func onTab(_ tty: String, _ body: String) -> String {
        """
        tell application "Terminal"
            repeat with wi from 1 to count of windows
                repeat with ti from 1 to count of tabs of window wi
                    if tty of tab ti of window wi is "/dev/\(tty)" then
                        \(body)
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """
    }

    /// The visible text of the tab, nil when the tty has no Terminal tab.
    private func screen(_ tty: String) -> TermScreen? {
        let r = run(onTab(tty, "return contents of tab ti of window wi"))
        guard let text = r.value, !text.isEmpty else { return nil }
        return TermScreen(text)
    }

    /// `do script` types the expression's text followed by return.
    private func type(_ expr: String, tty: String) -> Bool {
        let r = run(onTab(tty, "do script \(expr) in tab ti of window wi\nreturn \"ok\""))
        if let e = r.error { log("type failed: \(e)") }
        return r.value == "ok"
    }

    private func focusNow(_ tty: String) -> Bool {
        let r = run(onTab(tty, """
            if miniaturized of window wi then set miniaturized of window wi to false
            set selected tab of window wi to tab ti of window wi
            set frontmost of window wi to true
            activate
            return "ok"
            """))
        if let e = r.error { log("focus failed: \(e)") }
        return r.value == "ok"
    }

    /// Types a slash command into the tab.
    func send(_ command: String, toTTY tty: String) {
        guard valid(tty), command.range(of: "^/[a-z-]+$", options: .regularExpression) != nil else { return }
        queue.async {
            if self.type("\"\(command)\"", tty: tty) { log("sent \(command) to \(tty)") }
        }
    }

    func focus(tty: String) {
        guard valid(tty) else { return }
        queue.async { _ = self.focusNow(tty) }
    }

    // ── remote-control for every session ────────────────

    /// Runs /remote-control in each tab. Turning it on is that alone. Turning it off opens a menu whose
    /// cursor starts on "Continue", the last entry; "Disconnect this session" is the first, and five ups
    /// land on it whether the menu has two or three entries and whether or not it wraps around.
    /// The ups are only sent once the menu is on screen: in the prompt they would recall an old message
    /// and the return would send it. `done` runs on the bridge queue with the number of tabs switched.
    func rcAll(on: Bool, ttys: [String], done: @escaping (Int) -> Void) {
        queue.async {
            var ok = 0
            for tty in ttys where self.valid(tty) {
                guard let s = self.screen(tty), s.hasPrompt else {
                    log("rc all \(on ? "on" : "off"): skipped \(tty) (no Terminal tab, or it is showing a dialog)")
                    continue
                }
                guard self.type("\"/remote-control\"", tty: tty) else { continue }
                if on { ok += 1; continue }
                var menu = false
                for _ in 0..<15 where !menu {
                    usleep(200_000)
                    menu = self.screen(tty)?.contains("Disconnect this session") ?? false
                }
                guard menu else { log("rc all off: no disconnect menu on \(tty)"); continue }
                let up = "((ASCII character 27) & \"[A\")"
                if self.type([String](repeating: up, count: 5).joined(separator: " & "), tty: tty) { ok += 1 }
            }
            log("rc all \(on ? "on" : "off"): \(ok)/\(ttys.count)")
            done(ok)
        }
    }

    // ── voice dictation ─────────────────────────────────

    enum VoiceOp { case toggle, cancel }
    enum VoiceResult: String { case recording, sent, cancelled, idle, noTab, blocked, notStarted }

    /// A key press delivered to Terminal's key window. `do script` cannot do this: it always adds a return,
    /// which would send a half-typed prompt, and Claude Code drops the dictation if the prompt changes under it.
    private func press(_ key: CGKeyCode) -> Bool {
        guard let term = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return false }
            e.flags = []
            e.postToPid(term.processIdentifier)
            usleep(20_000)
        }
        return true
    }

    /// Whether the tab shows Claude Code recording. nil when the tab is gone.
    func isRecording(tty: String, _ done: @escaping (Bool?) -> Void) {
        guard valid(tty) else { return }
        queue.async { done(self.screen(tty)?.recording) }
    }

    /// Toggle: Space starts dictation, or stops it and sends what was said (Claude Code's "tap" voice mode).
    /// Cancel: Esc while recording discards it; Esc is never pressed otherwise, it would interrupt a running turn.
    /// The tab is brought to the front first because the key goes to whichever tab has the keyboard.
    /// `done` runs on the bridge queue.
    func voice(_ op: VoiceOp, tty: String, done: @escaping (VoiceResult) -> Void) {
        guard valid(tty) else { return }
        queue.async {
            guard self.focusNow(tty) else { done(.noTab); return }
            usleep(300_000)
            let front = self.frontScript?.executeAndReturnError(nil).stringValue ?? ""
            guard front == "/dev/\(tty)", let before = self.screen(tty) else { done(.noTab); return }
            let was = before.recording
            if op == .cancel {
                if was { _ = self.press(53) }
                done(was ? .cancelled : .idle)
                return
            }
            guard was || before.hasPrompt else { done(.blocked); return }
            guard self.press(49) else { done(.noTab); return }
            if was { done(.sent); return }
            for _ in 0..<8 {
                usleep(250_000)
                if self.screen(tty)?.recording == true { done(.recording); return }
            }
            done(.notStarted)
        }
    }
}

// ── app ─────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    var trayItem: NSCustomTouchBarItem!
    var trayButton: NSButton!
    let usageCell = makeCell()
    var backButton: NSButton!
    var micButton: NSButton!
    var cancelButton: NSButton!
    let hintLabel = NSTextField(labelWithString: "")
    let leadStack = NSStackView()
    let cellStack = NSStackView()
    let actionStack = NSStackView()
    let rcCell = makeCell()
    var bar: NSTouchBar!
    var visibleObservation: NSKeyValueObservation?
    let terminal = TerminalBridge()
    let keepAwake = KeepAwake()
    var termSource: DispatchSourceSignal?

    var mode: Mode = .list
    var last = Render()
    var ticks = 0
    var sessionTTYs: [String: Int] = [:]   // tty -> claude pid, from the latest snapshot
    var rcOnPids: Set<Int> = []            // sessions with remote-control on, from the latest snapshot
    var voice: (tty: String, pid: Int)?    // the session that is recording dictation
    var voiceBusy = false
    var rcBusy = false
    var callBusy = false
    var hintSerial = 0

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
        micButton = NSButton(image: NSImage(named: NSImage.touchBarAudioInputTemplateName)!, target: self, action: #selector(micTapped))
        micButton.isHidden = true
        cancelButton = NSButton(title: "✕", target: self, action: #selector(voiceCancelTapped))
        cancelButton.font = line1Font
        cancelButton.isHidden = true
        hintLabel.font = line2Font
        hintLabel.textColor = .systemOrange
        hintLabel.isHidden = true
        leadStack.addArrangedSubview(backButton)
        leadStack.addArrangedSubview(micButton)
        leadStack.addArrangedSubview(cancelButton)
        leadStack.addArrangedSubview(hintLabel)
        leadStack.addArrangedSubview(usageCell)

        cellStack.orientation = .horizontal
        cellStack.spacing = 22
        cellStack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        rcCell.setContentHuggingPriority(.required, for: .horizontal)
        actionStack.orientation = .horizontal
        actionStack.spacing = 6
        for cell in [usageCell, rcCell] {
            let tap = NSClickGestureRecognizer(target: self, action: #selector(cellTapped(_:)))
            tap.allowedTouchTypes = .direct
            cell.addGestureRecognizer(tap)
        }

        bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.lead, .cells, .actions, .rc]

        installTray()
        keepAwake.onChange = { [weak self] in self?.refresh() }
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { [weak self] in
            self?.keepAwake.restoreForExit()
            exit(0)
        }
        termSource?.resume()
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
        case .actions:
            item.view = actionStack
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

    /// info -> detail -> list
    @objc func backToList() {
        if case .info(let pid, _) = mode, pid > 0 { setMode(.detail(pid)) } else { setMode(.list) }
    }

    var modePid: Int {
        switch mode {
        case .list: return 0
        case .detail(let pid), .info(let pid, _): return pid
        }
    }

    @objc func cellTapped(_ g: NSGestureRecognizer) {
        guard let cell = g.view as? Cell else { return }
        if cell.pid > 0 {
            setMode(.detail(cell.pid))
            if let tty = ttyName(of: pid_t(cell.pid)) { terminal.focus(tty: tty) }
        } else if !cell.key.isEmpty {
            if case .info = mode { return }
            setMode(.info(modePid, cell.key))
        }
    }

    @objc func actionTapped(_ b: ActionButton) {
        if let a = b.action_, a.local {
            switch a.command {
            case "allow-sleep":
                keepAwake.toggleAllowSleep()
                refresh()
            case "rc-all-on", "rc-all-off":
                rcAll(on: a.command == "rc-all-on", button: b)
            case "call-on", "call-off":
                guard !callBusy else { return }
                callBusy = true
                b.title = "…"
                let on = a.command == "call-on"
                DispatchQueue.global(qos: .userInitiated).async {
                    setCall(on: on)
                    // the bot writes its status file a moment after it starts
                    DispatchQueue.main.asyncAfter(deadline: .now() + (on ? 2.5 : 0.8)) {
                        self.callBusy = false
                        self.last.actions = []
                        self.refresh()
                    }
                }
            default:
                break
            }
            return
        }
        guard let a = b.action_, modePid > 0, let tty = ttyName(of: pid_t(modePid)) else { return }
        if a.confirm && !b.armed {
            b.armed = true
            b.attributedTitle = NSAttributedString(string: "run \(a.command) ?", attributes: [.font: line1Font, .foregroundColor: NSColor.systemOrange])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak b] in
                guard let b = b, b.armed else { return }
                b.armed = false
                b.attributedTitle = NSAttributedString(string: a.command, attributes: [.font: line1Font])
            }
            return
        }
        terminal.send(a.command, toTTY: tty)
        terminal.focus(tty: tty)
        setMode(.detail(modePid))
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        refresh()
    }

    /// Switches remote-control for every session that is not already in the wanted state.
    func rcAll(on: Bool, button: NSButton) {
        guard !rcBusy else { return }
        let ttys = sessionTTYs.filter { rcOnPids.contains($0.value) != on }.map { $0.key }.sorted()
        guard !ttys.isEmpty else { return }
        rcBusy = true
        button.title = "…"
        terminal.rcAll(on: on, ttys: ttys) { ok in
            // the session files catch up a moment after the command lands
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.rcBusy = false
                self.last.actions = []   // rebuild the buttons even when the same set comes back
                if ok < ttys.count { self.showHint("\(ok)/\(ttys.count) switched · see log") }
                self.refresh()
            }
        }
    }

    // ── voice dictation ─────────────────────────────────

    /// The session the mic button talks to: the one being shown, or the only one there is.
    var micTarget: (tty: String, pid: Int)? {
        if let v = voice { return v }
        let pid = modePid > 0 ? modePid : (sessionTTYs.count == 1 ? sessionTTYs.first!.value : 0)
        guard pid > 0, let tty = sessionTTYs.first(where: { $0.value == pid })?.key else { return nil }
        return (tty, pid)
    }

    func showHint(_ text: String) {
        hintSerial += 1
        let serial = hintSerial
        hintLabel.stringValue = text
        hintLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, self.hintSerial == serial else { return }
            self.hintLabel.isHidden = true
        }
    }

    func updateMic() {
        micButton.isHidden = micTarget == nil
        micButton.bezelColor = voice == nil ? nil : .systemRed
        cancelButton.isHidden = voice == nil
    }

    @objc func micTapped() { voiceKey(.toggle) }
    @objc func voiceCancelTapped() { voiceKey(.cancel) }

    func voiceKey(_ op: TerminalBridge.VoiceOp) {
        guard !voiceBusy, let target = micTarget else { return }
        guard voiceTapEnabled() else { showHint("voice is off · run /voice tap"); return }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            log("voice: no Accessibility permission")
            showHint("allow Accessibility for ClaudeTouchBar")
            return
        }
        voiceBusy = true
        terminal.voice(op, tty: target.tty) { result in
            DispatchQueue.main.async {
                self.voiceBusy = false
                log("voice \(op) on \(target.tty): \(result.rawValue)")
                switch result {
                case .recording: self.voice = target
                case .sent, .cancelled, .idle: self.voice = nil
                case .noTab: self.voice = nil; self.showHint("no Terminal tab for this session")
                case .blocked: self.showHint("session is asking something")
                case .notStarted: self.showHint("not recording · prompt not empty?")
                }
                self.updateMic()
            }
        }
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
        if let v = voice, !voiceBusy {
            // stopped from the keyboard, or the session ended
            terminal.isRecording(tty: v.tty) { rec in
                DispatchQueue.main.async {
                    guard rec != true, !self.voiceBusy, self.voice?.tty == v.tty else { return }
                    self.voice = nil
                    self.updateMic()
                }
            }
        }
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
            var snap = loadSnapshot(withShells: visible)
            snap.awake = self.keepAwake.update(rcOn: snap.sessions.contains { !$0.bridge.isEmpty })
            snap.allowSleep = self.keepAwake.allowSleep
            var ttys: [String: Int] = [:]
            for s in snap.sessions { if let t = s.tty { ttys[t] = s.pid } }
            let rcOn = Set(snap.sessions.filter { !$0.bridge.isEmpty }.map { $0.pid })
            let r = render(snap, mode: m)
            DispatchQueue.main.async {
                self.sessionTTYs = ttys
                self.rcOnPids = rcOn
                self.updateMic()
                guard m == self.mode else { return }
                self.apply(r)
            }
        }
    }

    func apply(_ r: Render) {
        let isList = mode == .list
        backButton.isHidden = isList
        usageCell.isHidden = !isList
        if case .info = mode { backButton.title = "‹ back" } else { backButton.title = "‹ all" }
        usageCell.key = r.usage.key
        rcCell.key = r.rc.key

        if r.actions != last.actions {
            for v in actionStack.arrangedSubviews {
                actionStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            for a in r.actions {
                let b = ActionButton(title: a.title, target: self, action: #selector(actionTapped(_:)))
                b.font = line1Font
                b.action_ = a
                actionStack.addArrangedSubview(b)
            }
        }

        if r.trayText != last.trayText || r.trayState != last.trayState || r.trayAwake != last.trayAwake || trayButton.title == "cc" {
            // the teal dot takes over from Capsomnia's Caps Lock lamp: sleep is disabled right now
            let title = NSMutableAttributedString(string: r.trayAwake ? "●" : "", attributes: [
                .font: NSFont.systemFont(ofSize: 7), .foregroundColor: awakeColor, .baselineOffset: 3,
            ])
            // the strip clips anything wider than the button, so "●100%" loses its percent sign
            let text = r.trayAwake && r.trayText.count > 3 ? String(r.trayText.dropLast()) : r.trayText
            title.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: color(for: r.trayState) ?? .white,
            ]))
            trayButton.attributedTitle = title
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
                c.key = row.key
                c.attributedStringValue = twoLines(row)
            }
        }
        last = r
    }
}

// Command-line use, mostly for testing without a finger on the bar. Run from Terminal these borrow
// Terminal's own Automation and Accessibility permissions.
//   ClaudeTouchBar --rc-all on|off [claude pid]
//   ClaudeTouchBar --voice <claude pid> toggle|cancel
if CommandLine.arguments.count >= 3 {
    let args = CommandLine.arguments
    let sessions = loadSnapshot(withShells: false).sessions
    let bridge = TerminalBridge()
    let wait = DispatchSemaphore(value: 0)
    if args[1] == "--rc-all", ["on", "off"].contains(args[2]) {
        let on = args[2] == "on"
        let only = args.count >= 4 ? args[3] : ""   // optional: just this claude pid
        let ttys = sessions.filter { $0.bridge.isEmpty == on && (only.isEmpty || "\($0.pid)" == only) }.compactMap { $0.tty }
        bridge.rcAll(on: on, ttys: ttys) { ok in print("switched \(ok)/\(ttys.count)"); wait.signal() }
        wait.wait()
        exit(0)
    }
    if args[1] == "--voice", args.count >= 4, let s = sessions.first(where: { "\($0.pid)" == args[2] }), let tty = s.tty {
        guard voiceTapEnabled() else { print("voice is off: run /voice tap"); exit(1) }
        guard AXIsProcessTrusted() else { print("no Accessibility permission"); exit(1) }
        bridge.voice(args[3] == "cancel" ? .cancel : .toggle, tty: tty) { r in print(r.rawValue); wait.signal() }
        wait.wait()
        exit(0)
    }
    print("usage: ClaudeTouchBar [--rc-all on|off [claude pid] | --voice <claude pid> toggle|cancel]")
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
log("started")
app.run()
