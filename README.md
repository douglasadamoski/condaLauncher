# condaLauncher

**One bash script per web tool to check, start, stop and inspect every version of it,
each running in its own conda environment.**

Lab and research web tools (R/Shiny, Flask, FastAPI, Streamlit, anything that serves HTTP)
tend to collect several versions side by side and a different pair of hand-written
`start.sh` / `stop.sh` scripts for each. condaLauncher replaces those with one script per
tool: a logo, a menu you can drive with arrow keys or the mouse, verbose PASS/FAIL checks,
and servers that keep running after you close the terminal.

It needs nothing but **bash ≥ 4.4 and coreutils**, so it runs in a plain terminal (or over
SSH) *before* any conda environment is active.

```
   ██████╗  ██████╗   ██████╗ ██████╗            ▄▄▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  ██╔═══██╗ ██╔══██╗ ██╔════╝ ██╔══██╗          ▄▀    ▄▄▀▀▀▀▀▀▀▀▀▀
  ██║   ██║ ██████╔╝ ██║      ██████╔╝         ▄▀   ▄▀     ▄▀▀▀▀▀▀
  ██║▄▄ ██║ ██╔═══╝  ██║      ██╔══██╗  ╌╌╌╌╌╌█╌╌╌╌▄▀╌╌╌▄▄▀╌╌╌╌╌╌╌ Ct
  ╚██████╔╝ ██║      ╚██████╗ ██║  ██║  ▄▄▄▄▀▀▄▄▄▀▀▄▄▄▄▀▄▄▄▄▄▄▄▄▄▄
   ╚══▀▀═╝  ╚═╝       ╚═════╝ ╚═╝  ╚═╝    ● 18.4 ● 23.1 ● 27.9 ○ NTC

  qPCR Analyzer · launcher v0.1.3 · lab-server · ● 1 running

  Main menu

  ❯ 1  Preflight checks   conda env, packages, files, port
    2  Start server       version ➜ env ➜ banner ➜ launch
    3  Stop server        ● 1 running
    4  Diagnostics        what runs where, health, logs
    5  Help               what this tool is and how to use it
    6  Exit

  ↑↓/jk move · ⏎ or click select · 1-6 jump · q back
```

*(A real tool's launcher, with its own logo. In the terminal the logo has a colour gradient
and the curves are coloured.)*

## Features

- **Menu**: full screen, with arrow keys, j/k, number keys, mouse hover and click, and
  the scroll wheel. It is redrawn only where it changes, so nothing flickers. Without a
  terminal (cron, `ssh host cmd`, CI) every action is available as a flag.
- **Every version, found automatically**: each `v*` folder that contains the tool's entry
  file is launchable; broken ones are listed with the reason. The version started last
  is preselected.
- **Conda without activation**:
  - Environments are found by a bash scan plus `mamba/conda env list`. Only those with the
    right interpreter (`Rscript` or `python`) are shown.
  - The env recorded for this version on this machine is preselected.
  - A new env is created from the explicit lockfile, or from `environment.yml` after a
    dry run and a y/N.
  - The server runs with the env's own interpreter. There is no `conda activate` or
    `conda run`, so stop signals reach the server.
- **Verbose checks**: every step prints `✔ PASS / ⚠ WARN / ✘ FAIL` with its timing. A
  failure shows its output and a fix command, and each action ends with an `x/y PASS`
  summary box. Reports are saved without colour codes.
- **Package checks in one call**: all R or Python requirements are loaded in a single
  interpreter call, with version pins (`shiny>=1.7`, `yaml:pyyaml`).
- **Background servers**:
  - Servers start with `setsid` and keep running after you close the terminal.
  - Records hold the pid, user and start time, so a recycled pid is never mistaken for
    your server.
  - Stop sends SIGTERM to the whole process group, waits, then sends SIGKILL, and checks
    that the port is free.
- **Several versions at once**: each has its own port, with fallback to the next free
  port. The health check is an HTTP GET in pure bash (no curl). Logs are rotated.
- **Dev banner**: Start asks whether to show it (yes by default for `ROLE=dev`) and hands
  it to the tool as `CL_BANNER`, with snippets for Shiny, Flask and FastAPI.
- **Shared folders**: records carry the host name; servers started on another machine are
  shown and probed, never killed. A `flock` stops two launchers colliding.
- **Your logo**:
  - a built-in block font, a pasted ASCII/ANSI-art logo, or a `logo.txt`
  - inline colour markup (`{r}`, `{g}`, `{b}`, … then `{/}`)
  - Tokyo Night theme with light/dark detection, ASCII fallback, `NO_COLOR`
- **JSON output** for status, diagnostics, preflight and env listing.

## Install

```bash
# the whole repo (docs, demo, tests)
git clone https://github.com/douglasadamoski/condaLauncher
# or just the script from the latest release
curl -fsSLO https://github.com/douglasadamoski/condaLauncher/releases/latest/download/condaLauncher.sh
chmod +x condaLauncher.sh
```

## Quick start

```bash
condaLauncher/v0.1/condaLauncher.sh init /path/to/my-tool   # asks a few questions
/path/to/my-tool/launch-mytool.sh                           # the menu
```

`init` detects the app type (Shiny, or a Python file using Flask, FastAPI, uvicorn,
Streamlit or Dash), the versions, the port and the env name, and writes
`launch-<tool>.sh`. Then list the packages the tool needs in its config block and run
**Preflight**.

Expected layout of a tool:

```
my-tool/
  launch-mytool.sh            the launcher: config block on top, engine below
  logo.txt                    optional
  v1.0/  v1.1/ ...            one complete copy of the app per version
    app.R | server.py         the entry file
    deploy/version.env        optional: ROLE=prod|dev  PORT=  BANNER=  BIND=
    deploy/environment.yml    optional, plus an explicit *.lock.txt
  run/                        created by the launcher (state, logs, reports); git-ignore it
```

Without the menu:

```bash
./launch-mytool.sh start --version v1.1 --env myenv --banner on --yes
./launch-mytool.sh status --json
./launch-mytool.sh stop --all --yes
./launch-mytool.sh help
```

Try the bundled demo (any conda env with Python 3 will do):

```bash
cd v0.1/examples/demo-tool && ./launch-demo.sh
bash v0.1/tests/run_all.sh          # 38 end-to-end tests
```

## Documentation

| | |
|---|---|
| [USAGE.md](v0.1/docs/USAGE.md) | menu, flags, files, every config variable, logos, site settings, upgrading |
| [TOOL_CONTRACT.md](v0.1/docs/TOOL_CONTRACT.md) | what a tool must provide; showing the dev banner in Shiny, Flask, FastAPI |
| [AI_AGENTS.md](v0.1/docs/AI_AGENTS.md) | **making Claude Code, Codex, opencode, Gemini, Cursor, Copilot … use condaLauncher** |
| [site.env.example](v0.1/site.env.example) | machine-specific settings, kept out of every repo |
| [CHANGELOG.md](CHANGELOG.md) | what changed in each release |

## Using it with AI coding CLIs

If you ask coding agents for "a script to start the server", you get a different one every
time. Put the rule from [AI_AGENTS.md](v0.1/docs/AI_AGENTS.md) in the agent's instruction
file (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, Cursor rules, Copilot instructions). From then
on, "make a bash launcher for this tool" makes the agent:

1. run `init`
2. fill in only the ~30-line config block
3. verify with preflight, start, status and stop before reporting back

The guide has the copy-paste rule, a table of where each CLI reads its instructions,
example prompts and a review checklist.

## Versions and upgrades

- Each minor version lives in its own folder (`v0.1/`), so older ones keep running.
- Every release is a git tag with notes and the script attached
  ([Releases](https://github.com/douglasadamoski/condaLauncher/releases)).
- A tool's launcher takes a newer engine without losing its configuration:

```bash
./launch-mytool.sh upgrade /path/to/condaLauncher/v0.1/condaLauncher.sh
```

## Privacy

A tool's launcher is meant to be committed with the tool, so it holds **no
machine-specific values**:
- Conda locations are found at run time.
- Site-specific settings (an extra env folder, envs that must never be installed into, a
  file mode) go in `~/.config/condaLauncher/site.env`.
- Per-host records (`run/`, `deploy/launcher.local`) belong in the tool's `.gitignore`.

This repo uses `tools/check-private.sh` as a pre-commit hook to refuse commits that contain
host names, home or mount paths, or private IP addresses.

## Contributing

- Run the tests: `bash v0.1/tests/run_all.sh`. To test the menu by hand, drive it with tmux:
  `send-keys` for keys, `send-keys -H` with SGR bytes for mouse events, and
  `CL_DEBUG_KEYS=file` to log what the launcher received.
- Install the privacy hook: `ln -s ../../tools/check-private.sh .git/hooks/pre-commit`.
- Engine changes go in the newest `vX.Y/condaLauncher.sh`, together with an entry in
  `CHANGELOG.md` and a test.

## Licence

[MIT](LICENSE)
