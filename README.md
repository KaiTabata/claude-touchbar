# claude-touchbar

A tiny Touch Bar status display for [Claude Code](https://claude.com/claude-code) sessions on Touch Bar MacBooks.

```
Control Strip:   26%        green = idle · orange = a session is running · red = 5h limit ≥ 90%

List view:       5h 26% ↻ 1h12    ● my-app ⎇ main*  Fix login bug        ● notes  Thesis outline          remote-control
                 7d 23% ↻ 5d12h     RUN 3m · ctx 13% · sh×1 · RC           IDLE 12m · ctx 37%                     ● 1/2 on

Detail view:     ‹ all   ● ~/src/my-app            ● $ npm run dev    ⎇ main*         ctx 13%          fable-5.1 …   remote-control
                           RUN 3m · pid 73776 · ttys004  shell · 2m   Fix login bug   153k / 1M tok    effort high …   ● on · session_01…
```

- **Control Strip item** – the 5-hour rate-limit percentage, always visible, colored by state.
- **List view** (tap the item) – rate limits with reset countdowns, one cell per live session
  (directory, git branch, session name, RUN/IDLE time, context %, running shell commands, remote-control).
- **Detail view** – tap a session to bring its Terminal tab to the front and see everything about it:
  path, pid/tty, running Bash-tool commands, context tokens, model/effort/fast/thinking, lines changed,
  uptime/API time/cost, prompt-cache TTL and hit rate, version, remote-control status.
- **Explains itself** – tap any detail cell for an explanation (in Japanese) plus related slash commands
  (`/model`, `/fast`, `/config`, `/context`, `/compact`, `/usage`, `/status`, `/remote-control`). Tapping a command types it
  into that session's Terminal tab; `/compact` asks for a second tap.
- **Follows you** – while a Terminal tab running Claude Code is frontmost, the bar shows that session automatically.
- **Replaces other apps' Touch Bars** – while an app listed in `apps.txt` (Safari and Chrome by default) is frontmost,
  the list view is shown instead of that app's controls. Edit the file to add or remove apps; no rebuild needed.

## Load

No child processes, no network. It reads a few small JSON files and queries the kernel (`sysctl`) for
process info: every 2 s while the bar is visible or Terminal is in front, every 10 s otherwise.
The process table is only scanned while the bar is visible. Measured: ~0% CPU, ~60 MB RSS.

## Requirements

- A MacBook Pro with a Touch Bar, macOS 15+ (developed on macOS 26), Xcode Command Line Tools (`swiftc`)
- Terminal.app (tab detection and focusing use its AppleScript interface)
- Claude Code with a statusline script, plus `jq`

## Install

```sh
git clone <this repo> ~/.config/claude-touchbar
cd ~/.config/claude-touchbar
./install.sh        # builds ClaudeTouchBar.app and installs a KeepAlive LaunchAgent
```

Then paste `statusline-snippet.sh` into your statusline script. Claude Code only hands context,
model, cost and rate-limit data to the statusline, so that is where the app gets it from.

On first use macOS asks whether ClaudeTouchBar may control Terminal – allow it. Rebuilding changes the
ad-hoc signature, so the prompt comes back after each `./build.sh`.

Uninstall:

```sh
launchctl bootout gui/$(id -u)/space.tabataba.claude-touchbar
rm ~/Library/LaunchAgents/space.tabataba.claude-touchbar.plist
```

## How it works / caveats

- There is no public API for a system-wide Touch Bar. This uses the same private calls as MTMR and Pock
  (`DFRElementSetControlStripPresenceForIdentifier`, `+[NSTouchBarItem addSystemTrayItem:]`,
  `+[NSTouchBar presentSystemModalTouchBar:…]`). A macOS update can break it; check `touchbar.log`.
- The Control Strip silently drops third-party items, so the app re-asserts its registration every few
  seconds and reinstalls it on wake, when ControlStrip relaunches, and after the bar closes.
- Session data comes from undocumented Claude Code files (`~/.claude/sessions/<pid>.json`). Remote-control
  is treated as on when `bridgeSessionId` is present. Running shell commands are the claude process's
  children whose arguments reference `~/.claude/shell-snapshots/`. Any of this may change between versions.
- The session title is Claude Code's session name: change it with `/rename <name>` or start with `claude -n <name>`.
