# Changelog

## v0.1.5 (2026-11-18)

- **Port by role:** a tool that sets both `CL_PORT_PROD` and `CL_PORT_DEV` gets its port from the banner question:
  no banner (production) starts on `CL_PORT_PROD`, a banner (development) on `CL_PORT_DEV`. `PORT=` in
  `version.env` is then ignored and preflight warns about it; `--port` still overrides. Before the banner is
  chosen (`status`, `preflight`) the version's `ROLE` decides. When the role port is busy the usual fallback scan
  skips both role ports, so production can never land on the development port. Requested for NMD-Predict
  (8685 prod / 8686 dev).
- `init` writes the two new (empty) settings into the config block.
- Tests: 8 more (banner on/off, `--yes` with ROLE=prod/dev, the ignored `PORT=`, the fallback, `--port`); 51 without caddy.

## v0.1.4 (2026-11-16)

- **Pool mode:** `start --workers N` (or `WORKERS=N` in `version.env`) starts N server processes on loopback
  ports and a Caddy proxy on the normal port. Browsers are pinned to a worker by cookie, new ones go to the
  least busy worker, health checking is passive only. For tools that block while working (a Shiny app
  exporting a file) this stops one user from freezing the others. `status` lists the workers, `stop` takes the
  pool down together, preflight checks the proxy and offers to install it. Workers get `CL_POOL=1` so a tool
  can keep per-worker scratch space (docs/TOOL_CONTRACT.md). Settings: `CL_POOL_PROXY`, `CL_POOL_COOKIE`,
  `CL_POOL_TIMEOUT`, `CL_POOL_MAX_BODY`.
- **Opt-in and menu:** a tool declares `CL_WORKERS_MAX` (>= 2) and optionally `CL_WORKERS_DEFAULT`; only then does *Start server* ask
  "How many workers?" (from "One process" up to the maximum) and `--workers N` work. Without the declaration `--workers 2` is refused;
  `--workers 1` always starts one plain process. Workers listen on 127.0.0.1 only; the proxy owns the one public port.
- A command listed in `CL_REQUIRE_CMDS` that is missing from the env is now offered for install, the same way a
  missing R or Python package is (`--install`, or `y` at the terminal; `--yes` alone never installs). Before, it
  only printed a fix line. An entry may be `cmd=condapackage` when the two names differ.
- The server environment moved into one function (`_server_env`) shared by single and pool starts.
- Tests: 55 (pool start/stop, stickiness, spread, a worker stuck on a request, the install offer, the opt-in, the default). The pool tests
  need caddy on PATH or `CL_TEST_CADDY=/path/to/caddy`; without it they are skipped.

## v0.1.3 (2026-11-08)

- Fixed: when a picker with fewer rows followed a longer one (e.g. the banner question
  after the env list), the extra rows of the previous picker stayed on screen. Every
  redraw now clears below its last row.

## v0.1.2 (2026-11-08)

- Logo colour markup: `{r} {g} {b} {y} {m} {c} {d} {B}` pick theme colours inside a logo
  line, and `{/}` returns to the gradient. Widths ignore the markup, and it is removed
  when colour is off. See docs/USAGE.md, section "Logo".

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
