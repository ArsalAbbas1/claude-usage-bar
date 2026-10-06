# How it works

The internals behind [the README](../README.md): where each number comes from,
and the measurements behind the design choices.

## Rate limits

Polls `https://api.anthropic.com/api/oauth/usage` every 5 minutes — the same endpoint
`/usage` uses inside Claude Code. The OAuth token is read fresh on each poll from
the `Claude Code-credentials` Keychain item, via `/usr/bin/security`, so token
rotations by Claude Code are picked up automatically and no credential is stored
by this app.

If the API call fails (no token, expired token, offline), it falls back to
`cachedUsageUtilization` in `~/.claude.json`, which Claude Code refreshes while
it runs. That value can be well over an hour old, so the bar marks it with `~`
and the menu says `cached`.

Opening the menu never triggers a fetch — only the 5-minute timer and **Refresh
Now** do. The endpoint rate-limits at roughly one request per minute and returns
`Retry-After` on 429; that header is honoured rather than guessed at (with a
60-second floor), and the app falls back to the cache, marked `~`, meanwhile.

### Colours

Neutral under 70%, `systemOrange` at 70%+, `systemRed` at 90%+ — the stock macOS
system colours, which follow Light and Dark Mode on their own. Each window is
coloured by its own number, so a healthy 5-hour window stays neutral while the
7-day one turns orange.

### Pace forecast

Live readings of the 5-hour window are kept for an hour and fitted with a line:
`full by <time>` when that line crosses 100% before the reset, otherwise
`on pace — ~N% at reset`. It needs 15 minutes of readings in the current window
first, since they arrive every 5 minutes in whole-percent steps. Cached readings
are never used.

## Sessions and agents

Counts come from two places, all local file reads with no API requests.

**Top-level sessions** are registered by Claude Code at
`~/.claude/sessions/<pid>.json` with a `status` of `busy`, `idle` or `waiting`.
Each entry is confirmed with `kill(pid, 0)`, since the file outlives a crash.

**Subagents** run in-process and have no pid, so they are counted from the
parent's transcript: an `Agent` tool_use is pending until it finishes. A
foreground agent finishes when a `tool_result` quotes its id. A background agent
gets that `tool_result` immediately (marked `toolUseResult.isAsync`), so for
those the finish is the later `<task-notification>` carrying `<tool-use-id>`.

Transcripts are read incrementally — each pass reads only bytes appended since
the last — on a background queue. The first pass over a 40 MB transcript takes
about a second; after that it is a few KB a minute.

### Labels

Each session is labelled with its Conductor chat title ("Claude usage tracker
Mac") rather than Claude Code's derived name ("worcester-a6"), joined on
`claude_session_id` against Conductor's sqlite database, opened read-only.
Sessions not started from Conductor fall back to their git branch, then to the
derived name.

### Control panel rows

- **Needs you.** Sessions whose `status` is `waiting` (a permission dialog or
  question), longest wait first, with `waitingFor` alongside. The menu bar gains
  a `⚑N` prefix, and a notification fires once a wait passes a minute. Clicking
  the notification brings Conductor forward.
- **Working.** How long each busy turn has run. Context size appears only from
  200k (orange) and 500k (red): auto-compact fires near the full window, so a
  session can sit at several hundred k for hours. `⚠ silent` flags a busy
  session whose transcript and subagent transcripts have not been written for
  10 minutes.
- **Cache.** Idle and waiting rows show the last request's cache hit and how
  long until its prompt cache lapses (`97% hit · 42m warm`), or `cache cold`. The TTL (1h or 5m)
  comes from the request's cache write. Busy rows omit it; they refresh their
  own cache every turn.
- **Kept warm** rows are pinned sessions (`↻`); other idle sessions fold into a
  submenu.

## The spinner

The spinner is a layer-backed `CAShapeLayer` with a Core Animation rotation, not
an animated title. Re-setting an `NSStatusItem` title measured **~13 ms a frame**
because it forces the entire menu bar to re-measure — 2.93% CPU at just 2 fps,
6.62% at 8 fps. Handing a layer to the compositor instead costs **0.37%** at
60 fps, indistinguishable from idle.

## Keep Cache Warm

A pinned session gets a ping when 10 minutes are left on a 1h cache (2 minutes
on a 5m one). The ping replays the session's cached prefix, which resets the TTL,
so the next real turn reads its context at cache-read prices instead of
rewriting all of it. On a 1h cache, rewriting costs 2× the input price and a
read costs 0.1×, so one avoided cold turn pays for about 20 pings, roughly 17
hours of pinning.

The ping is `claude -p --resume <id> --fork-session --no-session-persistence`,
launched with the live process's own executable, argv and environment (read
with `KERN_PROCARGS2`). Claude Code records the system prompt on the first
request and resume re-sends that record, so with the same model, thinking,
effort, tools and setting sources the prefix is byte-identical. Measured: 63.7k
of a 64k context read back from cache, and 173k of 170k. Only I/O, identity
and permission flags are dropped. Default permissions deny any tool call,
hooks are off, and `--max-turns 1` caps it. Nothing is written to the
session's transcript.

Guards:
- **Cold sessions are left alone.** Re-warming one costs the full rewrite the
  next real turn would pay anyway.
- **A ping that misses gets unpinned.** If it reads less than 90% of the
  session's last context from cache, it warmed a different prefix, and repeating
  it would pay write prices every time.
- **Pins expire** after 8 hours or when the session ends.
- **Pings pause** while the 5-hour window is at 90% or more.
- Every ping is logged to `~/.config/claude-usage-bar/keepwarm.log`, with its
  token counts and list-price cost. Pins are stored in `pins.json` next to it.

```bash
ClaudeUsage --ping <pid> --dry-run   # the exact command a ping would run
ClaudeUsage --ping <pid>             # one real ping; exit 2 if it missed the cache
```

## Memory

Every 10 seconds, and at once when the kernel changes the pressure level, one
`sysctl` lists this user's processes and `proc_pid_rusage` reads each one's
physical footprint: the number Activity Monitor shows as "Memory". A sample of
about 420 processes took 6 ms, and the menu rebuild after it another 6 ms, so
the two cost about 0.1% of one core.

- **Pressure** is `kern.memorystatus_vm_pressure_level`, the kernel's own
  verdict. Free memory misleads: it read 48% at warning while the compressor
  held 6 GB. The menu bar shows `mem`, orange at warning and red at critical,
  and nothing at normal.
- **Sessions.** A session's tree starts at the `claude` pid in its registry
  entry, which is re-read for every sample. An entry outlives a crash and its
  pid is soon reused, so the entry counts only if that process started before
  the entry's `startedAt`. Each direct child is a *command*: a Bash tool call
  (its shell and everything under it), a background task, or an MCP server. A
  session started inside a command is its own session, not part of the
  command. A command is named after its largest process, since its root is
  usually a shell. A row shows its session's memory from 1 GB (orange) and 4 GB
  (red); a claude process alone measured 160–350 MB.
- **Largest apps.** Processes outside the sessions are summed per app by the
  outermost `.app` bundle in their path, so Chrome's helpers count as Chrome.
  Web views, Safari's and other apps', run in shared WebKit processes and show
  as `WebKit`.

### Caps

All are off by default. They are set from the Memory row's submenu and saved
under `memory` in `~/.config/claude-usage-bar/config.json`, where a cap edited
by hand counts only from 0.5 to 512 GB.

| Setting | Choices | What it stops |
|---|---|---|
| **Command cap** | off, 2, 3, 4 GB | a command that passes the cap |
| **Session cap** | off, 4, 6, 8 GB | the session's largest command, once all its commands together pass the cap |
| **At critical** | notify, or notify and stop | the largest command of any session, if it holds at least 1 GB |

A command counts everything under it, so one that keeps forking is caught even
though each of its processes is small. A session's claude process is never
stopped and never counts toward a cap: stopping commands could not bring it down.

Stopping a command notifies you, sends `SIGTERM`, and sends `SIGKILL` 10 seconds
later to whatever is still running. A Bash tool call's shell leads its own
process group, so the signal goes to the whole group, which also reaches
processes forked since the last sample. Two kinds of command are signalled one
sampled process at a time instead:

- **MCP servers**, which share their session's group. A process a server
  forked since the last sample is missed, and if the server exits first, that
  process leaves the session's tree.
- **A command with a session inside it**, such as `claude -p` run from a Bash
  tool call. That session shares the command's group, and it and its MCP
  servers are left running.

A sampled process is signalled on its own only if its start time still
matches, so a reused pid is never hit. A session's claude process is never
signalled once it has registered, a few seconds after it starts; the registry
is read fresh for each signal. Every stop and every change of cap is logged to
`~/.config/claude-usage-bar/memory.log`.

At critical pressure the app notifies at most once every 15 minutes, naming the
largest apps; clicking the notification opens Activity Monitor. **Notify and
stop** also stops the largest command, but only one of at least 1 GB: the
pressure is usually another app's, and a small command frees too little to
help. Within 20 seconds of any stop it only notifies, since the memory that
stop frees may not be back yet.

macOS gives an ordinary app no hard memory limit on another process, so a cap
acts at the next sample, up to 12 seconds after it is crossed: the timer may
fire 2 seconds late so macOS can batch it with other wakeups.

## Debugging

macOS status items and their menus do not appear in `screencapture` output, so
the binary has a headless mode that prints exactly what the menu would show:

```bash
ClaudeUsage --dump                 # what the menu bar shows
ClaudeUsage --dump --cache-only    # exercise the offline fallback path
ClaudeUsage --agents               # session rows as the dropdown shows them
ClaudeUsage --memory               # memory readings behind the badge and rows
ClaudeUsage --memory --command-cap 1   # what a 1 GB command cap would stop, without stopping it
./test.sh                          # unit-test the reader, session model, pace forecast and memory
```
