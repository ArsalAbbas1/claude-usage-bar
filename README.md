# Claude Usage Bar

**Your Claude Code rate limits, running agents and prompt caches, in the macOS menu bar.**

```
⚑1  5h 13%  7d 79%  ⟳ 2 busy (+3)
```

![The dropdown in the classic theme](docs/themes/classic.png)

Native Swift, a single binary, no dependencies, no Xcode project. Idle CPU is
indistinguishable from zero.

## What's new

| Date | Release | What landed |
|---|---|---|
| 6 Oct 2026 | **v0.4** | **Keep Cache Warm** — pin an idle session and its prompt cache never lapses. The next real turn read 99% of its context from cache. |
| 3 Oct 2026 | **v0.3** | **Control panel** — a *Needs you* queue for sessions blocked on a dialog, a **5-hour pace forecast** (`full by 3:40 PM`), and a flag for busy sessions that have gone silent. |
| 24 Sep 2026 | **v0.2** | **Live agent counts** — busy/waiting/idle sessions plus in-flight subagents, labelled with Conductor chat titles. |
| 20 Sep 2026 | **v0.1** | **Usage in the menu bar** — 5-hour and 7-day utilisation, coloured as they near the limit. |

Full history: [CHANGELOG.md](CHANGELOG.md).

## Features

- **Rate limits at a glance.** 5-hour and 7-day windows, each turning orange at
  70% and red at 90% using stock macOS colours.
- **Pace forecast.** A line fitted to the last hour of readings tells you whether
  the 5-hour window will fill before it resets. It reflects your real plan limit,
  including claude.ai and other machines.
- **Needs you.** Sessions waiting on a permission dialog or question jump to the
  top, badge the menu bar with `⚑N`, and notify you after a minute.
- **Working sessions.** Turn duration, context size once it passes 200k, and
  `⚠ silent` when a busy session has written nothing for 10 minutes — usually a
  hung tool or MCP call.
- **Agent counts.** Top-level sessions and background subagents (`2 busy (+3)`),
  with a spinner in the menu bar while anything runs.
- **Prompt cache status.** Each idle session shows its last cache hit and time
  until the cache lapses (`97% hit · 42m warm`), or `cache cold`.
- **Keep Cache Warm.** Pin a session and it is pinged shortly before the cache
  expires, so coming back to it costs cache-read prices, not a full rewrite.
  One avoided cold turn pays for about 20 pings.
- **Memory.** `mem` in the menu bar while macOS reports memory pressure, orange
  at warning and red at critical. The dropdown's Memory row shows swap and what
  Claude Code sessions hold, with the largest apps in its submenu, and a session
  holding 1 GB or more says so on its row.

Works with any Claude Code session. If you use [Conductor](https://conductor.build),
sessions are labelled with their chat titles and get an **Open in Conductor** action.

## Install

Requires macOS 13+, the Xcode Command Line Tools, and Claude Code signed in on
this Mac.

```bash
git clone https://github.com/sakthi535squad/claude-usage-bar.git
cd claude-usage-bar
./build.sh            # builds and installs /Applications/ClaudeUsage.app
open -a ClaudeUsage
```

On first launch macOS asks to let the app read the `Claude Code-credentials`
Keychain item — choose **Always Allow**. Enable **Open at Login** from the menu.

## Privacy and cost

- **One network call:** `GET https://api.anthropic.com/api/oauth/usage`, every
  5 minutes, the same endpoint Claude Code's `/usage` uses. It is undocumented
  and may change.
- **Your token stays in the Keychain.** It is read fresh on each poll and never
  stored or sent anywhere else.
- **Everything else is local:** file reads of `~/.claude` (and Conductor's
  database, read-only), and the process table for memory. None of it costs
  anything against your rate limit.
- **Keep Cache Warm spends tokens.** Each ping is a one-turn `claude -p` call at
  cache-read prices. Pins expire after 8 hours, pause when the 5-hour window
  reaches 90%, and every ping is logged with its cost to
  `~/.config/claude-usage-bar/keepwarm.log`.

## Command line

```bash
ClaudeUsage --dump                  # print what the menu bar shows
ClaudeUsage --dump --cache-only     # exercise the offline fallback
ClaudeUsage --agents                # session rows as the dropdown shows them
ClaudeUsage --memory                # pressure, swap, and what each session's processes hold
ClaudeUsage --ping <pid> --dry-run  # the exact command a keep-warm ping would run
./test.sh                           # unit tests
```

`ClaudeUsage` is `/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage`.

## How it works

Rate-limit polling and backoff, how agents and subagents are counted from
transcripts, why the spinner is a Core Animation layer (0.37% CPU at 60 fps vs
6.6% for an animated title), and how a keep-warm ping reproduces a session's
cache prefix byte-for-byte: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Roadmap

- Customisable colour thresholds, per window, with a time-aware warning for the
  5-hour window ([#2](https://github.com/sakthi535squad/claude-usage-bar/issues/2)).

Ideas and bug reports are welcome in [Issues](https://github.com/sakthi535squad/claude-usage-bar/issues).

## License

[MIT](LICENSE)
