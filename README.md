# battlens

`battlens` is a native macOS CLI that logs:

- battery level over time
- awake time over time, based on real sleep/wake notifications
- unplugged sessions so you can estimate usable time per charge
- charging sessions so you can see charge-up pace and time-to-full estimates

## Build

```bash
swift build -c release
```

## Quick start

Run the tracker in the foreground:

```bash
.build/release/battlens track --interval 300 --verbose
```

Render a report:

```bash
.build/release/battlens report --days 7 --sessions 8
```

Open the interactive terminal dashboard:

```bash
.build/release/battlens tui
.build/release/battlens dashboard --refresh 5 --days 7
```

Log a one-off sample:

```bash
.build/release/battlens snapshot
```

## Run in the background

Install a `launchd` agent so tracking resumes automatically after login:

```bash
.build/release/battlens install-agent --interval 300 --executable "$(pwd)/.build/release/battlens"
```

Remove it later with:

```bash
.build/release/battlens uninstall-agent
```

## Data location

By default BattLens stores its data in:

```text
~/Library/Application Support/battlens
```

You can override that with `BATTLENS_DATA_DIR=/some/path`.

## Notes

- `track` records battery samples on startup, on wake, on sleep, when the power source changes, and on a repeating timer.
- `tui` and `dashboard` open a live terminal dashboard. Use `q` to quit, arrow keys to switch views or select sessions, `t` to cycle ranges, `s` to log a snapshot, and `i`/`u` to install or remove the launch agent.
- Awake time is tracked as "time not asleep", which is usually the best proxy for actual laptop-use time in terminal tools.
- The report merges overlapping awake spans, tracks discharge sessions for per-session and cross-session full-charge awake runtime estimates, and tracks charging sessions for pace and time-to-full estimates.
