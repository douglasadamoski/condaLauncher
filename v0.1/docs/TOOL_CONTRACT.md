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

Other `version.env` keys are available to the `cl_tool_env()` hook as `V_<KEY>`. Use the
hook when the tool already reads its own variable names:

```bash
cl_tool_env() {
  export MYTOOL_BANNER="$CL_BANNER" MYTOOL_FEATURE_X="${V_FEATURE_X:-on}"
  export TMPDIR="$CL_VDIR/data/tmp"; mkdir -p "$TMPDIR"
}
```

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
