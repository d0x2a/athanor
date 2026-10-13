# Athanor

A macOS menu bar app that keeps a list of shell scripts and runs them for you:
start, stop and restart them from the menu bar, see their CPU, memory and
ports, read their output, and have the ones that crash restarted.

An athanor is the alchemist's furnace built to hold a steady heat. The menu bar
glyph is the furnace: empty when nothing runs, a flame when something does, and
a red dot when a script has crashed and stayed down.

Requires macOS 14 or later on Apple silicon.

## Installing

```sh
brew install --cask d0x2a/tap/athanor
```

Or download the DMG from [Releases](https://github.com/d0x2a/athanor/releases)
and drag Athanor to Applications. It's signed and notarized.

## Using it

Click the furnace in the menu bar (or press ⌥⌘A) for the list. Each script
shows whether it's running, its CPU and memory, the ports it listens on and how
long it has been up. Expand one for its pid, the last lines of its output and
Restart, Open log, Edit and Copy command.

- **Add a script** with **+**, or start from one of the examples on the empty
  list. Each script runs with `/bin/sh -c`, so pipes, `&&`, variables and
  several lines all work. End with `exec program …` so Stop reaches the
  program itself rather than only the shell.
- **Ready when** decides when a starting script counts as up: as soon as it
  starts, once a port is open on localhost, or once a URL answers. Until then
  its dot pulses.
- **Crashes**: a script that exits non-zero (or dies from a signal) is
  restarted after 1, 3, 10, then 30 seconds, up to the limit you set within a
  window (3 within 5 minutes by default). Past the limit it stays down, moves
  to the top of the list in red, and the menu bar glyph gets a red dot until
  you start it again or dismiss it. Exit code 0 counts as finished, not crashed.
- **Stop** sends the script's stop signal (SIGTERM by default) to its whole
  process group, so pipelines and child processes stop too, then SIGKILL if it
  is still running after the timeout (10 seconds by default).
- **Logs** opens every script's output, with timestamps, a filter, an
  Errors-only view and CPU and memory charts for the last 30 minutes.
- **Quitting Athanor** leaves scripts running by default; the next launch finds
  them again. Settings can make quitting stop them, or ask.

Scripts started from the Dock or at login don't get the PATH a Terminal
window has, so Homebrew, pip and nvm tools can't be found. Athanor asks your
login shell for its environment once at launch and gives it to every script
that has **Use the environment from my login shell** on (the default).

## Files

| What | Where |
| --- | --- |
| Script list | `~/.config/athanor/scripts.toml` (`$XDG_CONFIG_HOME/athanor` if set) |
| Logs | `~/Library/Logs/Athanor/<id>.log`, rotated to `<id>.log.1` at the size cap |
| Run state | `~/Library/Application Support/Athanor/run/<id>.json` |

`ATHANOR_HOME=/some/folder` puts all three under one folder instead.

### scripts.toml

The script list is plain TOML, meant to be edited by hand or kept with your
dotfiles. Athanor reloads it a second after it changes. If it doesn't parse,
the popover says which line is wrong and Athanor keeps the last version that
worked.

```toml
[[script]]
id = "rapid-mlx"            # names the log and run state; set once
name = "rapid-mlx"
command = '''
export HF_HOME="$HOME/models/hf"
exec rapid-mlx serve mlx-community/Qwen3-8B-4bit
'''
cwd = "~/models"
env = { PYTHONUNBUFFERED = "1" }
login_env = true            # start from the login shell's environment
autostart = true            # start when Athanor opens
restart = true              # restart after a crash…
restart_limit = 3           # …at most this many times…
restart_window = 300        # …within this many seconds
stop_signal = "TERM"        # TERM, INT, HUP or QUIT
stop_timeout = 10           # seconds before SIGKILL
ready = "port"              # "started", "port" or "url"
port = 8000                 # with ready = "port"
# url = "http://127.0.0.1:8000/health"   # with ready = "url"

[[script]]
command = "caffeinate -dims"  # everything else has a default
```

Only `command` is required. Without `id`, one is made from the name; without
`name`, the first word of the command is used. Keys Athanor doesn't know are
ignored. Saving from the app rewrites only the entry of the script you
changed; the rest of the file, comments included, stays as you wrote it.

### Log lines

Each line of a log is `date time stream text`, where the stream is `out`
(stdout), `err` (stderr) or `ath` (Athanor noting a start, stop, restart or
exit):

```
2026-10-12 09:41:03.123 ath started · pid 48213 · ~/models
2026-10-12 09:41:09.002 out Listening on http://127.0.0.1:8000
2026-10-12 09:41:09.010 ath ready · port 8000 is open
```

## How it works

Athanor doesn't run scripts as its own children. Each running script gets an
`athanor-shim`, a small helper shipped inside the app, started in a session of
its own. The shim runs the script with `/bin/sh -c` in a new process group,
writes its output to the log with timestamps, and records the pids and how
the script ended in the run-state file. Because shims don't depend on the app,
quitting or updating Athanor doesn't touch running scripts, and the next
launch picks them up from the run-state files, after checking each pid still
belongs to the same shim.

CPU, memory (physical footprint, as Activity Monitor shows) and listening TCP
ports come from libproc every 2 seconds, summed over the script's process
tree and process group.

## Building

```sh
swift test                   # unit tests, plus the real shim end to end
./scripts/run-dev.sh         # debug build in build/dev, signed ad hoc, opened
ATHANOR_HOME=/tmp/ath ./scripts/run-dev.sh   # …on a scratch set of scripts
./scripts/build-release.sh   # signed, notarized and stapled app and DMG in build/release
```

`build-release.sh` signs with the Dox2A Labs Developer ID and notarizes with
the `kuddo-notary` keychain profile; see the comments at the top for the
environment variables that change that. `NOTARIZE=0` skips notarization for a
quick local check.

The dev build has its own bundle id (`com.d0x2a.athanor.dev`) and settings,
but uses the same script list unless `ATHANOR_HOME` is set. Only one Athanor
runs per script list: a second copy says so and quits.

`Athanor --snapshot DIR` renders the popover, the windows and the app icon to
PNGs in light and dark, from the current script list, without starting or
stopping anything.
