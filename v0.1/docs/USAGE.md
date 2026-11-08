# condaLauncher v0.1: usage

## Adding it to a tool

```bash
v0.1/condaLauncher.sh init /path/to/tool
```

`init` looks at the newest `v*` folder. It recognises `app.R`/`server.R` as Shiny, and a
Python file containing Flask, FastAPI, uvicorn, http.server, streamlit or Dash as Python.
It also reads `deploy/version.env` for a port and `environment.yml` for the env name.
It asks for the name, short name, kind, entry file, port, env and description, then writes
`/path/to/tool/launch-<short>.sh`. Afterwards:

1. Fill `CL_REQUIRE_R` or `CL_REQUIRE_PY` in the config block.
2. Optionally add a `cl_tool_env()` hook (see TOOL_CONTRACT.md).
3. Add `run/` and `*/deploy/launcher.local` to the tool's `.gitignore`.
4. Run it and choose **Preflight**.

Expected tool layout:

```
my-tool/
  launch-mytool.sh            the launcher (config block + engine)
  logo.txt                    optional; overrides the logo in the config
  v0.1/  v0.2/ ...            one complete copy of the app per version
    app.R | server.py         CL_ENTRY: must exist for the folder to be launchable
    deploy/version.env        optional: ROLE=prod|dev PORT= BANNER= BIND= (+ any keys)
    deploy/environment.yml    optional: env to create
    deploy/<env>.lock.txt     optional: explicit lockfile (preferred for creating)
  run/                        created by the launcher; never commit
```

## Menu

| Key | Action |
|---|---|
| ↑ ↓, j k, mouse wheel, moving the mouse over a row | move the highlight |
| Enter, left click | choose (the click runs on release, over the row it was pressed on) |
| 1–9 | run that entry directly |
| Home End PgUp PgDn | jump |
| space, a | toggle, toggle all (Stop checklist) |
| q, Esc | back / exit |

The screen is redrawn only where it changed, and the launcher stays in one full-screen
session from the main menu through the last picker, so nothing flashes between steps.
Mouse reports in SGR (1006), X10 and urxvt (1015) encodings are all understood. To see
exactly what a terminal sends, run with `CL_DEBUG_KEYS=/path/keys.txt`: one line per
key or mouse event, with the raw bytes.

To select text while the menu is open, hold Shift (PuTTY, MobaXterm, xterm) or Alt
(VS Code) while dragging. To turn mouse capture off, pass `--no-mouse`, or set
`LAUNCHER_MOUSE=0` or `MOUSE=0` in site.env; `CL_MOUSE_HOVER=0` keeps clicks but stops
hover tracking. In tmux, clicks reach the menu only with
`set -g mouse on`.

After an action the launcher exits and leaves its summary on screen; servers keep running.

## Commands and flags

```
launch-x.sh                         menu
launch-x.sh start [--version V] [--env NAME|PATH] [--banner on|off|TEXT]
                  [--port N] [--local | --bind ADDR] [--timeout S] [--yes]
launch-x.sh stop  [--version V | --all] [--force] [--yes]
launch-x.sh preflight [--version V] [--env E] [--json] [--install]
launch-x.sh status [--json]         diagnostics printed once
launch-x.sh diagnostics             live table: r refresh, l logs, q exit
launch-x.sh logs [--version V] [-f]
launch-x.sh envs [--json]
launch-x.sh upgrade /path/to/new/condaLauncher.sh
launch-x.sh help
any: --no-mouse --ascii --no-color --theme night|day
```

Without a terminal (cron, `ssh host cmd`, CI), missing choices are taken from the
records: last started version, env recorded for this host, banner by role. If there is
no record, the launcher stops and names the flag to pass. `--yes` accepts defaults. It
**never** installs packages; only `--install`, or a `y` typed at the terminal, does that.

## Start, step by step

1. **Version**: the last one started on this host is preselected; broken folders are
   dimmed with the reason.
2. **Conda env**: only envs with the interpreter (`Rscript` or `python`) are listed. The
   preselection is the env recorded for this version on this host, else the name in
   `environment.yml`. The last row creates a new env: from the lockfile when there is a
   linux-64 one, otherwise from `environment.yml` with a dry run first, then y/N.
3. **Dev banner**: yes by default for `ROLE=dev`, no for prod. The text is
   `version.env BANNER`, else `CL_BANNER_TEMPLATE` (`{VERSION} {TOOL} {HOST} {DATE}`).
4. **Checks**: version folder, version.env, package manager, interpreter, every declared
   package (full load, version pins), commands, files, run folder, not already running,
   port (a busy port moves to the next free one with a WARN; `--port` never moves),
   bind address.
5. **Launch** via `setsid -f`. The process records its own pid, which is also its
   process group and session. The env is used by calling its interpreter directly, with
   `PATH`, `LANG`, `JAVA_HOME`, `GDAL_DATA`, `PROJ_DATA` and `GSETTINGS_SCHEMA_DIR` set;
   no `conda activate` and no `conda run`.
6. **Health**: an HTTP GET over bash `/dev/tcp` (no curl) until 2xx/3xx. If the process
   dies or the timeout expires, the last 10 log lines are shown.
7. **Ready card**: local and LAN URLs (clickable where the terminal supports it), log,
   stop command. A QR code is shown when `qrencode` is installed.

## Files written

| File | Content |
|---|---|
| `run/<version>@<host>.state` | pid, start time, port, bind, env, banner, role, log, command (parsed, never sourced) |
| `run/<version>@<host>.log` | server output; the last `CL_LOG_KEEP` (5) kept as `.1`…`.5` |
| `run/reports/*.log` | every Preflight/Start/Stop report, plain text, newest 20 kept |
| `run/last@<host>` | last version started here |
| `<version>/deploy/launcher.local` | `<host>.prefix=<env path>` and `default.name=` |

Several hosts may share the folder (NFS): records carry the host name, and records from
other hosts are shown and probed over the network, but never stopped.

## Configuration reference (config block)

| Variable | Default | Meaning |
|---|---|---|
| `CL_TOOL_NAME`, `CL_TOOL_SHORT`, `CL_DESCRIPTION` | | identity, help text |
| `CL_LOGO_TEXT` / `CL_LOGO` | short name | text for the built-in block font / pasted art |
| `CL_KIND` | python | shiny, python or custom |
| `CL_INTERPRETER` | Rscript for shiny, else python | binary looked up in `<env>/bin` |
| `CL_ENTRY` | | file that makes a version folder launchable |
| `CL_CMD` | per kind | bash array; placeholders `{INTERP} {PORT} {BIND} {VDIR} {PREFIX} {VERSION} {ENTRY}` |
| `CL_HEALTH_PATH` | / | path probed for HTTP 2xx/3xx |
| `CL_PORT_DEFAULT`, `CL_BIND_DEFAULT` | 8780, 0.0.0.0 | when version.env has no PORT/BIND (port + version index) |
| `CL_ENV_NAME`, `CL_ENV_YML`, `CL_ENV_LOCK` | | env name; files searched in the version folder, then the tool root |
| `CL_REQUIRE_R` | | `shiny bslib>=0.5 DT` |
| `CL_REQUIRE_PY` | | `import[:dist][op version]`, e.g. `yaml:pyyaml sklearn:scikit-learn>=1.3` |
| `CL_REQUIRE_FILES`, `CL_REQUIRE_CMDS` | | must exist in the version folder / on PATH in the env |
| `CL_START_TIMEOUT`, `CL_STOP_TIMEOUT` | 60, 10 | seconds |
| `CL_BANNER_TEMPLATE` | `DEVELOPMENT {VERSION} — not for real experiments` | |
| `CL_VERSION_GLOB`, `CL_VERSION_ENV`, `CL_ENV_RECORD` | `v*`, `deploy/version.env`, `deploy/launcher.local` | |
| `CL_PORT_SCAN`, `CL_LOG_KEEP`, `CL_LOG_WARN_MB`, `CL_REPORT_KEEP` | 50, 5, 50, 20 | |
| `cl_tool_env()` | | optional hook: export the tool's own variables |

## Site settings (never in a repo)

`~/.config/condaLauncher/site.env`, or the file named by `$CL_SITE_FILE`. Format is
key=value; the file is parsed, never sourced. See `site.env.example`.

## Upgrading a tool's launcher

```bash
./launch-mytool.sh upgrade /path/to/condaLauncher/v0.2/condaLauncher.sh
```

The text between `# >>> condaLauncher config >>>` and `# <<< condaLauncher config <<<`
is kept, and everything else is replaced. The result is syntax-checked before it replaces
the old file, and a `.bak` copy is left.

## Logo

The logo comes from, in this order:
1. `logo.txt` beside the launcher
2. `CL_LOGO` in the config block
3. `CL_LOGO_TEXT` drawn in the built-in block font

The logo should be plain text, 4–7 lines and at most about 70 columns, using only
single-width characters. Each line is coloured with the theme's vertical gradient. Within
a line, colour markup picks theme colours for parts of it: `{r}` red, `{g}` green, `{b}`
blue, `{y}` yellow, `{m}` magenta, `{c}` cyan, `{d}` dim, `{B}` bold, and `{/}` returns to
the gradient. Widths are measured without the markup, and without colour the markup is
dropped. Example (from the qPCR launcher):

```
██║▄▄ ██║ ...  {d}╌╌╌╌╌╌{r}█{d}╌╌╌╌{g}▄▀{d}╌╌╌{b}▄▄▀{d}╌╌╌╌╌╌╌ Ct{/}
```

## Look

Tokyo Night theme: Night on dark terminals, Day on light ones, detected by asking the
terminal for its background colour (dark when there is no answer, and always in tmux).
Override it with `--theme`, or `THEME`/`BACKGROUND` in site.env. Truecolor is used when
`COLORTERM=truecolor`, otherwise 256 or 16 colours. `NO_COLOR` is respected. Symbols
switch to ASCII when the locale is not UTF-8 (or with `--ascii`).
