# What a tool needs to provide

condaLauncher starts any command that serves HTTP on a port. A tool qualifies when:

1. **Each version is a folder** matching `CL_VERSION_GLOB` (default `v*`) next to the
   launcher, containing `CL_ENTRY`.
2. **It listens on the port and address it is given.** The command line is `CL_CMD`, with
   `{PORT}` and `{BIND}` replaced. The working directory is the version folder.
3. **It answers HTTP** on `CL_HEALTH_PATH` (default `/`) with a 2xx or 3xx once ready.
4. **It exits on SIGTERM** within `CL_STOP_TIMEOUT` seconds. Worker processes it starts
   stay in its process group and are stopped with it. A child that calls `setsid`
   itself escapes, so don't do that.
5. **It writes logs to stdout/stderr.** They go to `run/<version>@<host>.log`.

## Variables the tool receives

| Variable | Example |
|---|---|
| `CL_BANNER` | `DEVELOPMENT v0.2`, or empty for no banner |
| `CL_ROLE` | `dev` / `prod` / empty, from version.env |
| `CL_VERSION` | `v0.2` |
| `CL_PORT`, `CL_BIND` | `8782`, `0.0.0.0` |
| `CL_VDIR` | absolute path of the version folder |
| `CL_ENV_PREFIX` | the conda env in use |
| `CL_TOOL`, `CL_HOST` | tool name, short host name |
| `CL_POOL` | `1` in a pool worker (`start --workers N`), `0` otherwise |

Other `version.env` keys are available to the `cl_tool_env()` hook as `V_<KEY>`. Use the
hook when the tool already reads its own variable names:

```bash
cl_tool_env() {
  export MYTOOL_BANNER="$CL_BANNER" MYTOOL_FEATURE_X="${V_FEATURE_X:-on}"
  export TMPDIR="$CL_VDIR/data/tmp"; mkdir -p "$TMPDIR"
}
```

## Running as one of several workers

`start --workers N` (N >= 2) starts N copies of the tool on loopback ports (first free ports from
PORT+10, in `CL_PORT`) and a proxy on the public port. The proxy sticks each browser to one worker
by cookie, and sends a new browser to the worker with the fewest open requests. For a tool that
blocks while it works (a Shiny app exporting a file), this keeps everyone else responsive.

To opt in, set `CL_WORKERS_MAX` (and optionally `CL_WORKERS_DEFAULT`) in the launcher config block; the menu then asks how many workers.
What the tool must do:
- Serve a normal page at `CL_HEALTH_PATH` on `CL_PORT` and bind to `CL_BIND` (always 127.0.0.1 for a worker).
- **Not share scratch space between workers.** When `CL_POOL=1`, put temp files in a folder named after
  `CL_PORT` (`$CL_VDIR/data/tmp/w$CL_PORT`), or two workers will delete each other's files.
- Keep a session on one process: no state shared between workers except files it writes itself.
- Build links to itself from the browser's address, not from a fixed port (the public port differs
  from the worker's).

## Showing the dev banner

**R / Shiny**
```r
banner <- Sys.getenv("CL_BANNER")
ui <- fluidPage(
  if (nzchar(banner)) div(banner, style = "background:#b3261e;color:#fff;padding:6px 12px;font-weight:bold"),
  ...
)
```

**Flask**
```python
import os
BANNER = os.environ.get("CL_BANNER", "")
@app.context_processor
def banner(): return {"dev_banner": BANNER}
# template: {% if dev_banner %}<div class="dev-banner">{{ dev_banner }}</div>{% endif %}
```

**FastAPI / Starlette**
```python
BANNER = os.environ.get("CL_BANNER", "")
# pass BANNER into your template context, or expose GET /api/banner for a SPA
```

**Static site / SPA**: serve `/banner.json` from the server using `CL_BANNER`, or have
the server inject it into `index.html` at start-up.

Keep the bar unmissable: a full-width coloured band at the very top of every page. A dev
server that looks like production is how real work ends up on the wrong server.
