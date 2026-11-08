# Changelog

## v0.1.1 (2026-11-08)

Mouse and drawing fixes after the first test in MobaXterm, where a click had to be made
twice and the screen flashed.

- Hovering over a menu row highlights it; a click chooses it on release, over the row
  it was pressed on. The wheel still moves the highlight.
- One full-screen session from the main menu to the last picker. Before, every picker
  left and re-entered it, which flashed and turned mouse reporting off between steps,
  so the release of a click was lost.
- Only changed rows are redrawn, inside synchronized-update codes, and only after an
  event. Before, the whole screen was redrawn every second.
- Reads the X10 and urxvt (1015) mouse encodings besides SGR (1006), waits up to 300 ms
  for the rest of an escape sequence over slow SSH, and discards pending input when
  leaving full-screen mode. `CL_DEBUG_KEYS` now also logs the raw bytes.
- Fixed: the default banner text came out as `DEVELOPMENT {VERSION` (a `}` inside
  `${VAR:=default}`). A test now checks it.

## v0.1 (2026-11-08)

First version.

- Single bash script (bash ≥ 4.4, coreutils): config block plus engine; `init` writes a
  tool's launcher, and `upgrade` swaps the engine while keeping the config.
- Full-screen menu with arrow keys, j/k, 1–9, Home/End/PgUp/PgDn, mouse click and wheel
  (SGR 1006). It falls back to a numbered prompt, or to flags, without a terminal.
- Built-in 5-row block font for logos (vertical gradient), `logo.txt` override,
  Tokyo Night theme with background detection, ASCII fallback, `NO_COLOR`.
- Preflight / Start / Stop / Diagnostics / Help. Every step prints PASS/WARN/FAIL with a
  fix, an `x/y PASS` summary box, and a plain-text report in `run/reports/`.
- Conda: discovery by bash scan plus the frontend list; picker filtered to envs that have
  the interpreter; per-host record per version; creation from the lockfile or
  `environment.yml` with a dry run and y/N; one-call package checks for R and Python
  with version pins; installs only with `--install` or a typed y.
- Processes: `setsid -f` with a self-recorded pid; liveness by pid, uid and start time;
  port fallback; HTTP health check over `/dev/tcp`; group SIGTERM, then SIGKILL; log
  rotation; `flock` per tool and host; records from other hosts reported, never touched.
- Dev banner passed as `CL_BANNER`; defaults to on for `ROLE=dev`.
- `--json` for status, diagnostics, preflight and envs.
- Demo tool and 35 end-to-end tests (36 since v0.1.1).
