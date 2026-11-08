# Using condaLauncher with AI coding CLIs

condaLauncher was built so that coding agents (Claude Code, OpenAI Codex CLI, opencode,
Gemini CLI, grok, Cursor, GitHub Copilot, …) stop writing a new pair of throw-away
start/stop scripts for every tool. Give your agent the rule below once, and every later
"make me a launcher for this" produces the same tested script.

There are three parts:

1. **[Install the template](#1-install-the-template-once)** somewhere every project can reach.
2. **[Add the rule](#2-tell-your-agents-about-it)** to the instruction file each CLI reads.
3. **[Ask](#3-ask-for-a-launcher)** in plain words; the agent follows the checklist.

---

## 1. Install the template once

```bash
# pick a stable place; the examples below use ~/tools/condaLauncher
git clone https://github.com/douglasadamoski/condaLauncher ~/tools/condaLauncher
# or only the script, from the latest release:
mkdir -p ~/tools/condaLauncher && curl -fsSL -o ~/tools/condaLauncher/condaLauncher.sh \
  https://github.com/douglasadamoski/condaLauncher/releases/latest/download/condaLauncher.sh
chmod +x ~/tools/condaLauncher/condaLauncher.sh
```

In the snippets below, replace `TEMPLATE` with the full path to `condaLauncher.sh`
(e.g. `~/tools/condaLauncher/v0.1/condaLauncher.sh` for a clone).

## 2. Tell your agents about it

Every CLI reads an instruction file. Put the same rule in the file each one reads:

| CLI | Global (all projects) | Per project |
|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md` | `CLAUDE.md` (or `AGENTS.md` via `@AGENTS.md`) |
| OpenAI Codex CLI | `~/.codex/AGENTS.md` | `AGENTS.md` |
| opencode | `~/.config/opencode/AGENTS.md` | `AGENTS.md` |
| Gemini CLI | `~/.gemini/GEMINI.md` | `GEMINI.md` (or set it to read `AGENTS.md`) |
| grok CLI | see its docs | `AGENTS.md` / `CLAUDE.md` |
| Cursor | User Rules (settings) | `.cursor/rules/*.mdc` or `AGENTS.md` |
| GitHub Copilot | — | `.github/copilot-instructions.md` |

Tip: keep **one** file with the rule and symlink it to each global location, so the
CLIs never drift apart:

```bash
mkdir -p ~/.codex ~/.config/opencode
ln -sf ~/agent-rules.md ~/.codex/AGENTS.md
ln -sf ~/agent-rules.md ~/.config/opencode/AGENTS.md
echo "@$HOME/agent-rules.md" >> ~/.claude/CLAUDE.md     # Claude Code imports files with @
```

### The rule (copy-paste)

````markdown
## Webserver launchers: always condaLauncher

When I ask for a bash launcher, start/stop scripts, a "way to run the server", or a
webserver starter for a tool, do NOT write ad-hoc start/stop scripts. Use condaLauncher.

- Template: TEMPLATE  (docs: docs/USAGE.md and docs/TOOL_CONTRACT.md beside it)
- New tool: `TEMPLATE init <tool-folder>` writes `<tool-folder>/launch-<tool>.sh`.
  It runs without a terminal too (`</dev/null` takes the detected defaults).
- Then edit ONLY the config block between `# >>> condaLauncher config >>>` and
  `# <<< condaLauncher config <<<`:
  - `CL_KIND` (shiny | python | custom), `CL_ENTRY` (file that must exist in a version folder),
    `CL_CMD` (bash array; placeholders {INTERP} {PORT} {BIND} {VDIR} {PREFIX} {VERSION}),
    `CL_HEALTH_PATH` (an endpoint that returns 2xx/3xx when ready),
  - `CL_ENV_NAME`, and `CL_ENV_LOCK` / `CL_ENV_YML` if the tool has them,
  - `CL_REQUIRE_R` ("shiny DT>=0.30") or `CL_REQUIRE_PY` ("import[:dist][>=ver]", e.g. "yaml:pyyaml"),
    built from what the code actually imports, plus `CL_REQUIRE_FILES` for data the server needs,
  - variables the tool already reads (its own banner variable, TMPDIR, feature flags) go in a
    `cl_tool_env()` function in the config block.
- Versions are sibling folders matching `v*`. Per-version settings (ROLE=prod|dev, PORT,
  BANNER, BIND) go in `<version>/deploy/version.env`.
- The dev banner reaches the tool as the environment variable `CL_BANNER`; if the tool shows
  no banner yet, say so, don't invent UI unless asked.
- Never hand-edit the engine below the config block. Engine updates:
  `./launch-<tool>.sh upgrade TEMPLATE` (keeps the config block).
- No absolute paths, host names, user names or IPs in the launcher (it gets committed).
  Machine settings live in `~/.config/condaLauncher/site.env`.
- Add `run/` and `*/deploy/launcher.local` to the tool's `.gitignore`.
- Verify before saying it works, without a terminal:
  `CL_NO_TTY=1 ./launch-<tool>.sh preflight --version <v> --env <env>` (0 FAIL), then
  `start --version <v> --env <env> --yes`, `status --json`, `stop --version <v> --yes`.
  If the port is in use by something you did not start, do not stop it: test with
  `--port <free port> --local` instead. Leave nothing running unless asked.
- Never pass `--install` (it installs packages into the env) unless I asked for that.
````

## 3. Ask for a launcher

With the rule in place, short requests are enough:

> Make a bash launcher for this tool.

> Add a launcher to `~/projects/rnaseq-explorer`. The server is `server/app.py`
> (FastAPI via uvicorn), versions are `v1.0/` and `v1.1/`, port 8800, env `rnaseq`.

> Upgrade the launchers in `~/projects/*` to the newest condaLauncher.

What a good agent does with it (and what to check in its reply):

1. Reads the tool: entry file, server framework and flags, imports, data files, existing
   start scripts, `environment.yml` / lockfile, per-version settings.
2. Runs `init`, then fills the config block: requirements, files, `CL_CMD`, health path,
   `cl_tool_env()` for the tool's own variables.
3. Adds `deploy/version.env` per version if ports or roles differ.
4. Runs preflight, start, status and stop, and reports the PASS counts and HTTP codes.
5. Leaves old start/stop scripts in place unless you asked to remove them.

## Why a fixed launcher beats asking an agent each time

- **Same behaviour everywhere**: menu, checks, logs and stop logic are identical in every
  tool, so you learn them once.
- **Tested once**: process groups, stale pids, busy ports, conda without activation and
  terminals without mouse support are handled in the engine (38 end-to-end tests), not
  rediscovered per project.
- **Small diffs**: an agent only writes a ~30-line config block, which is easy to review.
- **Upgradable**: a fix in the engine reaches every tool with one `upgrade` command.
