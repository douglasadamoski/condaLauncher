# condaLauncher

One bash script per web tool to **check, start, stop and inspect every version** of it,
each running in a conda environment. It needs nothing but bash ≥ 4.4 and coreutils, so it
runs in a plain terminal *before* any conda env is active.

```
  ███  ████ █   █  ██
  █  █ █    ██ ██ █  █        Main menu
  █  █ ███  █ █ █ █  █
  █  █ █    █   █ █  █        ❯ 1  Preflight checks   conda env, packages, files, port
  ███  ████ █   █  ██           2  Start server       version ➜ env ➜ banner ➜ launch
                                3  Stop server        ● 2 running
  Demo Tool · launcher v0.1.0     4  Diagnostics        what runs where, health, logs
                                5  Help               what this tool is and how to use it
                                6  Exit
```

- **Menu** driven by arrow keys, j/k, number keys or the mouse (click and wheel), drawn
  full-screen. Without a terminal it falls back to a numbered prompt or to flags.
- **Versions found automatically**: every `v*` folder with the tool's entry file is
  launchable; broken ones are listed with the reason.
- **Conda**: lists environments without activating conda (a bash scan plus
  `mamba/conda env list`), shows only those with the right interpreter, preselects the one
  recorded for this version on this host, or creates one from the lockfile or
  `environment.yml` (after a dry run and a y/N).
- **Verbose checks**: every step prints `✔ PASS / ⚠ WARN / ✘ FAIL`, failures show
  their output and a fix command, and each action ends with an `x/y PASS` summary box.
  Reports are saved without colour codes in `run/reports/`.
- **Background servers** started with `setsid`; they keep running after the launcher
  exits. Process records include the start time, so a recycled pid is never mistaken
  for the server. Stop sends SIGTERM to the whole process group, waits, then sends SIGKILL.
- **Dev banner**: Start asks whether to show it (yes by default for `ROLE=dev`) and passes
  it to the tool as `CL_BANNER`.

## Quick start

```bash
git clone <this repo> condaLauncher
condaLauncher/v0.1/condaLauncher.sh init /path/to/my-tool   # asks a few questions
/path/to/my-tool/launch-mytool.sh                           # the menu
```

Try it on the bundled demo (needs any conda env with python):

```bash
cd v0.1/examples/demo-tool && ./launch-demo.sh
bash v0.1/tests/run_all.sh          # 38 end-to-end tests
```

## Layout

| Path | What |
|---|---|
| `v0.1/condaLauncher.sh` | the template and engine (one file) |
| `v0.1/docs/USAGE.md` | menu, flags, files, configuration reference |
| `v0.1/docs/TOOL_CONTRACT.md` | what a tool must provide; reading the dev banner in Shiny, Flask, FastAPI |
| `v0.1/site.env.example` | machine-specific settings, kept out of every repo |
| `v0.1/examples/demo-tool/` | two-version demo used by the tests |
| `v0.1/tests/run_all.sh` | end-to-end tests |
| `tools/check-private.sh` | pre-commit guard against host names, paths and addresses |

Old versions stay runnable in their own folders; git tags (`v0.1`, …) mark them.

## Privacy

A tool's launcher is meant to be committed with the tool, so it holds **no
machine-specific values**. Conda locations are discovered at run time; anything
site-specific (an extra env folder, envs that must never be installed into, a file mode)
goes in `~/.config/condaLauncher/site.env`, which is read but never written to a repo.
Per-host records (`run/`, `deploy/launcher.local`) belong in the tool's `.gitignore`.

MIT licence.
