# condaLauncher design (v0.1)

## Intent
Lab web tools (R/Shiny, Python) each keep several version folders side by side and run in
conda envs. Every tool used to get its own pair of start/stop scripts per version, written
from scratch each time. condaLauncher replaces those with one script per tool, the same
engine everywhere, so each new tool needs only a small config block.

## Goals
- One script per tool, covering every version folder, found again on every run.
- A menu operated with arrow keys and mouse: Preflight, Start, Stop, Diagnostics, Help, Exit.
- Verbose, numbered PASS/WARN/FAIL lines with fixes, plus an x/y summary.
- Servers keep running after the launcher exits.
- Runs before any conda env is active: bash ≥ 4.4 and coreutils only.
- Publishable: nothing machine- or person-specific in the repo.

## Non-goals (v0.1)
Authentication or reverse proxies; Windows-native shells; stopping servers on other hosts;
building a tool's dev-banner UI (the launcher only passes `CL_BANNER`).

## Decisions (from the preferences sheet)
| Area | Decision |
|---|---|
| Name | condaLauncher; per-tool file `launch-<tool>.sh` |
| Logo | block letters (built-in font), vertical gradient, inline with `logo.txt` override, falls back to a one-line wordmark when narrow |
| Look | Tokyo Night (night/day by background detection), Unicode with ASCII fallback, pointer `❯` menu, running badges, braille spinner, tab title |
| Input | full-screen alt screen; mouse on with `--no-mouse`; single click runs; arrows, j/k, 1–9, q/Esc; flags plus a numbered prompt without a terminal; no idle timeout |
| Config | config block between markers plus a per-version `deploy/version.env`; `upgrade` swaps the engine |
| Versions | `v*` folders that contain the entry file; preselect the last one started on this host |
| Banner | env var `CL_BANNER`; default on for ROLE=dev; template `DEVELOPMENT {VERSION} — not for real experiments`; Start order: version, env, banner |
| Conda | discovery = bash scan ∪ frontend list; picker shows envs that have the interpreter; preselect host record, then the yml name; create from lockfile, else yml, after a dry run and y/N; mamba > conda > micromamba; always a full package load; the env's binary is called directly; record per version and host; shared envs allowed without warning; missing packages: offer, then ask |
| Processes | `setsid -f` with a self-recorded pid; state in `run/<ver>@<host>.state`; liveness by pid, uid and start time; fixed port with fallback; 0.0.0.0 with a warning; HTTP health check; TERM, wait 10 s, then KILL; checklist stop; log per start, keep 5, warn above 50 MB; other hosts reported only; flock that waits 30 s |
| Output | icon, word, dot leaders, timing; failures expanded; rounded summary box; plain-text reports, keep 20; Vite-style URL list; QR code when qrencode is present; diagnostics table with refresh and logs; exit after each action; `--json` |
| Repo | MIT; `v0.1/` folders plus git tags; `init` command |

## Privacy rule
Repo files contain no host names, user names, share paths or LAN addresses. Site specifics
live in `~/.config/condaLauncher/site.env` (parsed). Per-host records live in the tool's
`run/` and `deploy/launcher.local`, both git-ignored. `tools/check-private.sh` runs as a
pre-commit hook, with patterns kept in an untracked file.

## Calls made during the build (not on the preferences sheet)
- The env record is `deploy/launcher.local`, not `deploy/env.local`: an existing tool
  already sources `env.local`, and host-keyed lines would break that.
- The banner variable is `CL_BANNER`; the sheet's example `WSL_BANNER` came from the
  working name.
- Step numbers are `[07]`, not `[07/14]`: the total is not known in advance, because
  packages and files are counted at run time. The summary gives x/y.
- `--yes` accepts defaults but never installs packages; that needs `--install` or a typed y.
- When the background colour cannot be detected (always the case inside tmux), dark is assumed.
