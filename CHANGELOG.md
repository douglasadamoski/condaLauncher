# Changelog

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
- Demo tool and 35 end-to-end tests.
