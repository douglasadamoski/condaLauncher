#!/usr/bin/env bash
# condaLauncher -- one script to check, start, stop and inspect every version of a
# conda-based web tool (R/Shiny, Python, anything with a command line).
#
# Runs in a plain terminal BEFORE any conda env is active: bash >= 4.4 and coreutils
# only. Everything tool-specific lives in the CONFIG block below; everything after it
# is the engine, identical in every tool, and replaced by `upgrade`.
#
#   ./launch-<tool>.sh                 interactive menu
#   ./launch-<tool>.sh help            full usage
#
# https://github.com/  (fill in when published)  ·  MIT licence  ·  see docs/USAGE.md

# >>> condaLauncher config >>>
# This is the TEMPLATE. Run `./condaLauncher.sh init <tool-folder>` to write a
# launcher for a tool, or copy this file and fill in the block by hand.
CL_TOOL_NAME=""                 # empty = template mode
CL_TOOL_SHORT=""
CL_DESCRIPTION=""
CL_LOGO_TEXT="condaLauncher"    # rendered with the built-in block font
CL_LOGO=""                      # or paste pre-rendered art here (a logo.txt beside the script wins)
# <<< condaLauncher config <<<

# =============================== ENGINE =====================================
# Do not edit below this line in a tool's launcher: `upgrade` replaces it.
CL_LAUNCHER_VERSION="0.1.1"

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "condaLauncher needs bash >= 4.4 (this is ${BASH_VERSION:-not bash})." >&2; exit 2
fi
set -o pipefail
shopt -s extglob nullglob

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
TOOL_ROOT="${CL_TOOL_ROOT:-$(dirname "$SELF")}"
HOST="$(hostname -s 2>/dev/null || uname -n)"; HOST="${HOST%%.*}"
RUN_DIR="$TOOL_ROOT/run"
NOW_EPOCH() { printf '%(%s)T' -1; }

# ---------------------------------------------------------------- defaults --
: "${CL_KIND:=python}"                     # shiny | python | custom
: "${CL_VERSION_GLOB:=v*}"
: "${CL_ENTRY:=}"                          # file that must exist inside a version folder
: "${CL_HEALTH_PATH:=/}"
: "${CL_PORT_DEFAULT:=8780}"
: "${CL_BIND_DEFAULT:=0.0.0.0}"
: "${CL_ENV_NAME:=}"
: "${CL_ENV_YML:=environment.yml deploy/environment.yml}"
: "${CL_ENV_LOCK:=}"
: "${CL_REQUIRE_R:=}"
: "${CL_REQUIRE_PY:=}"
: "${CL_REQUIRE_FILES:=}"
: "${CL_REQUIRE_CMDS:=}"
: "${CL_START_TIMEOUT:=60}"
: "${CL_STOP_TIMEOUT:=10}"
: "${CL_VERSION_ENV:=deploy/version.env}"
: "${CL_ENV_RECORD:=deploy/launcher.local}"
# (a "}" inside ${VAR:=default} would end the expansion early, hence the plain if)
[ -n "${CL_BANNER_TEMPLATE:-}" ] || CL_BANNER_TEMPLATE='DEVELOPMENT {VERSION} — not for real experiments'
: "${CL_PORT_SCAN:=50}"
: "${CL_LOG_KEEP:=5}"
: "${CL_LOG_WARN_MB:=50}"
: "${CL_REPORT_KEEP:=20}"
if [ -z "${CL_INTERPRETER:-}" ]; then
  case "$CL_KIND" in shiny|r|R) CL_INTERPRETER=Rscript ;; *) CL_INTERPRETER=python ;; esac
fi
if ! declare -p CL_CMD >/dev/null 2>&1 || [ "${#CL_CMD[@]}" -eq 0 ]; then
  case "$CL_KIND" in
    shiny|r|R) CL_CMD=('{INTERP}' -e "shiny::runApp('.', port={PORT}, host='{BIND}', launch.browser=FALSE)") ;;
    *)         CL_CMD=('{INTERP}' "${CL_ENTRY:-app.py}" --port '{PORT}' --host '{BIND}') ;;
  esac
fi

# ------------------------------------------------------------- site config --
# Machine-specific settings never live in a tool's launcher (which is committed to
# git). They come from an optional key=value file, parsed -- never sourced:
#   ~/.config/condaLauncher/site.env   or   $CL_SITE_FILE
# Keys: CONDA (path to mamba/conda), ENV_DIRS (extra env folders, space separated),
#       SHARED_ENVS (env names never installed into), FILE_MODE (e.g. 777),
#       THEME, BACKGROUND, MOUSE, ASCII.
SITE_CONDA=""; SITE_ENV_DIRS=""; SITE_SHARED_ENVS=""; SITE_FILE_MODE=""
SITE_THEME=""; SITE_BACKGROUND=""; SITE_MOUSE=""; SITE_ASCII=""
_load_site() {
  local f k v
  for f in "${CL_SITE_FILE:-}" "${XDG_CONFIG_HOME:-$HOME/.config}/condaLauncher/site.env"; do
    [ -n "$f" ] && [ -r "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"; [[ $line == *=* ]] || continue
      k="${line%%=*}"; k="${k//[[:space:]]/}"; v="${line#*=}"
      v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; v="${v#[\"\']}"; v="${v%[\"\']}"
      case "$k" in
        CONDA) SITE_CONDA="$v" ;; ENV_DIRS) SITE_ENV_DIRS="$v" ;; SHARED_ENVS) SITE_SHARED_ENVS="$v" ;;
        FILE_MODE) [[ $v =~ ^[0-7]{3,4}$ ]] && SITE_FILE_MODE="$v" ;;
        THEME) SITE_THEME="$v" ;; BACKGROUND) SITE_BACKGROUND="$v" ;; MOUSE) SITE_MOUSE="$v" ;; ASCII) SITE_ASCII="$v" ;;
      esac
    done < "$f"
    break
  done
}
_load_site
_mode() { [ -n "$SITE_FILE_MODE" ] && chmod "$SITE_FILE_MODE" "$@" 2>/dev/null; return 0; }

# ================================================================ terminal ==
TTY=""; TTY_OK=0; COLOR=0; DEPTH=16; UTF8=0; ALT_ON=0; RAW_ON=0; STTY_SAVED=""
MOUSE=1; JSON=0; ASSUME_YES=0; FORCE=0
_term_init() {
  if [ -z "${CL_NO_TTY:-}" ] && { exec {TTY}<>/dev/tty; } 2>/dev/null; then
    case "${TERM:-dumb}" in dumb|"") TTY_OK=0 ;; *) TTY_OK=1 ;; esac
  fi
  if [ -n "${NO_COLOR:-}" ]; then COLOR=0
  elif [ -n "${FORCE_COLOR:-}" ]; then COLOR=1
  elif [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then COLOR=1; fi
  case "${CL_COLOR_DEPTH:-}" in 24|256|16) DEPTH="$CL_COLOR_DEPTH" ;; *)
    case "${COLORTERM:-}" in truecolor|24bit) DEPTH=24 ;; *)
      case "${TERM:-}" in *256col*|xterm-kitty|alacritty|wezterm) DEPTH=256 ;; *) DEPTH=16 ;; esac ;; esac ;; esac
  local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  [[ $loc =~ [Uu][Tt][Ff]-?8 ]] && UTF8=1
  [ "${CL_ASCII:-$SITE_ASCII}" = 1 ] && UTF8=0
  case "${CL_MOUSE:-${LAUNCHER_MOUSE:-$SITE_MOUSE}}" in 0|off|no) MOUSE=0 ;; esac
}

# Tokyo Night. night = dark terminals, day = light ones.
#            name   truecolor      256  16
_pal_night=( acc "187;154;247" 141 35  acc2 "125;207;255" 117 36  ok "158;206;106" 150 32
             warn "224;175;104" 179 33  err "247;118;142" 211 31  dim "86;95;137" 60 90  link "122;162;247" 111 34 )
_pal_day=(   acc "152;84;241" 98 35    acc2 "0;113;151" 30 36     ok "88;117;57" 64 32
             warn "140;108;62" 94 33    err "245;42;101" 197 31    dim "132;140;181" 103 90 link "46;125;233" 32 34 )
C_ACC=""; C_ACC2=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_LINK=""; C_B=""; C_0=""; C_REV=""
G_FROM=""; G_TO=""
_fgc() { # rgb n256 n16 -> escape
  case "$DEPTH" in 24) printf '\033[38;2;%sm' "$1" ;; 256) printf '\033[38;5;%sm' "$2" ;; *) printf '\033[%sm' "$3" ;; esac
}
_detect_bg() { # OSC 11 query; prints dark|light (dark when unknown)
  local want="${CL_BACKGROUND:-${SITE_BACKGROUND:-auto}}"
  case "$want" in dark|light) echo "$want"; return ;; esac
  [ "$TTY_OK" = 1 ] || { echo dark; return; }
  [ -n "${TMUX:-}" ] && { echo dark; return; }   # tmux answers with its own default
  local saved resp="" c r g
  saved="$(stty -g <&"$TTY" 2>/dev/null)" || { echo dark; return; }
  stty -echo -icanon min 0 time 0 <&"$TTY" 2>/dev/null
  printf '\033]11;?\033\\' >&"$TTY"
  while IFS= read -rsn1 -t 0.2 -u "$TTY" c; do resp+="$c"; [[ $c == $'\a' || $resp == *$'\e\\' ]] && break; done
  stty "$saved" <&"$TTY" 2>/dev/null
  if [[ $resp =~ rgb:([0-9a-fA-F]{2})[0-9a-fA-F]*/([0-9a-fA-F]{2})[0-9a-fA-F]*/([0-9a-fA-F]{2}) ]]; then
    r=$((16#${BASH_REMATCH[1]})); g=$((16#${BASH_REMATCH[2]})); c=$((16#${BASH_REMATCH[3]}))
    if (( (299*r + 587*g + 114*c) / 1000 > 140 )); then echo light; else echo dark; fi
  else echo dark; fi
}
_theme_init() {
  [ "$COLOR" = 1 ] || return 0
  local bg; bg="$(_detect_bg)"
  case "${CL_THEME:-$SITE_THEME}" in day) bg=light ;; night) bg=dark ;; esac
  local -a p; if [ "$bg" = light ]; then p=("${_pal_day[@]}"); else p=("${_pal_night[@]}"); fi
  local i
  for ((i = 0; i < ${#p[@]}; i += 4)); do
    local e; e="$(_fgc "${p[i+1]}" "${p[i+2]}" "${p[i+3]}")"
    case "${p[i]}" in acc) C_ACC="$e"; G_FROM="${p[i+1]}" ;; acc2) C_ACC2="$e"; G_TO="${p[i+1]}" ;; ok) C_OK="$e" ;;
      warn) C_WARN="$e" ;; err) C_ERR="$e" ;; dim) C_DIM="$e" ;; link) C_LINK="$e" ;; esac
  done
  [ "$DEPTH" = 16 ] && C_DIM=$'\033[2m'
  C_B=$'\033[1m'; C_0=$'\033[0m'; C_REV=$'\033[7m'
}
# glyphs (Unicode when the locale is UTF-8, ASCII otherwise)
_glyphs() {
  if [ "$UTF8" = 1 ]; then
    G_OK="✔"; G_FAIL="✘"; G_WARN="⚠"; G_PTR="❯"; G_DOT="●"; G_ODOT="○"; G_ARR="➜"; G_DOTS="·"
    G_TL="╭"; G_TR="╮"; G_BL="╰"; G_BR="╯"; G_H="─"; G_V="│"; G_ELL="…"; G_UPDN="↑↓"; G_ENTER="⏎"
    G_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); G_TREE="└"; G_PIPE="│"; G_BOXON="[x]"; G_BOXOFF="[ ]"; G_CLOCK="⏱"
  else
    G_OK="+"; G_FAIL="x"; G_WARN="!"; G_PTR=">"; G_DOT="*"; G_ODOT="o"; G_ARR="->"; G_DOTS="-"
    G_TL="+"; G_TR="+"; G_BL="+"; G_BR="+"; G_H="-"; G_V="|"; G_ELL="..."; G_UPDN="up/down"; G_ENTER="Enter"
    G_SPIN=('|' '/' '-' '\'); G_TREE="\`"; G_PIPE="|"; G_BOXON="[x]"; G_BOXOFF="[ ]"; G_CLOCK="t"
  fi
}
_tty_size() { # sets ROWS COLS
  local s; s="$(stty size <&"$TTY" 2>/dev/null)" || s=""
  ROWS="${s% *}"; COLS="${s#* }"
  [[ $ROWS =~ ^[0-9]+$ && $ROWS -gt 0 ]] || ROWS=24
  [[ $COLS =~ ^[0-9]+$ && $COLS -gt 0 ]] || COLS=80
}
# Full-screen mode. It stays on across consecutive pickers (no flash between them)
# and is switched off only when normal output is printed (out, ask_*, print_header).
# Mouse: 1000 = clicks, 1003 = motion too (hover highlight), 1006 = SGR encoding.
MOUSE_HOVER="${CL_MOUSE_HOVER:-1}"; WINCHED=1; FRAME=(); PREV=()
_raw_on() {
  [ "$RAW_ON" = 1 ] && return
  STTY_SAVED="$(stty -g <&"$TTY" 2>/dev/null)"
  stty -echo -icanon min 1 time 0 <&"$TTY" 2>/dev/null
  printf '\033[?1049h\033[?25l\033[H\033[2J' >&"$TTY"; ALT_ON=1
  if [ "$MOUSE" = 1 ]; then
    printf '\033[?1000h' >&"$TTY"; [ "$MOUSE_HOVER" = 1 ] && printf '\033[?1003h' >&"$TTY"; printf '\033[?1006h' >&"$TTY"
  fi
  PREV=(); WINCHED=1; RAW_ON=1
  trap 'WINCHED=1' WINCH
}
_raw_off() {
  [ "$RAW_ON" = 1 ] || return 0
  [ "$MOUSE" = 1 ] && printf '\033[?1006l\033[?1003l\033[?1000l' >&"$TTY"
  # swallow input already in flight (the release of the last click, motion reports),
  # or it would be echoed onto the normal screen
  local _junk; while IFS= read -rsn1 -t 0.05 -u "$TTY" _junk; do :; done
  printf '\033[?25h\033[?1049l' >&"$TTY"; ALT_ON=0
  [ -n "$STTY_SAVED" ] && stty "$STTY_SAVED" <&"$TTY" 2>/dev/null
  trap - WINCH
  RAW_ON=0
}
# Draw FRAME (one string per screen row), sending only the rows that changed since
# the last draw, inside a synchronized-update block (ignored where unsupported).
_frame_flush() {
  local o=$'\033[?2026h' i n=${#FRAME[@]} m=${#PREV[@]}
  for ((i = 0; i < n; i++)); do
    [ "${FRAME[i]}" = "${PREV[i]-$'\001'}" ] || o+=$'\033['"$((i + 1))"';1H'"${FRAME[i]}"$'\033[K'
  done
  (( m > n )) && o+=$'\033['"$((n + 1))"$';1H\033[J'
  o+=$'\033[?2026l'
  printf '%s' "$o" >&"$TTY"
  PREV=("${FRAME[@]}")
}
_cleanup() { _raw_off; [ -n "${SPIN_PID:-}" ] && kill "$SPIN_PID" 2>/dev/null; [ "$TTY_OK" = 1 ] && printf '\033[?25h' >&"$TTY"; }
trap _cleanup EXIT
trap 'exit 130' INT TERM HUP
_title() { [ "$TTY_OK" = 1 ] && [ "$COLOR" = 1 ] && printf '\033]0;%s\007' "$1" >&"$TTY"; return 0; }

# ================================================================== logo ===
# Built-in 5-row block font, so any tool gets a logo with no figlet installed.
declare -A FONT=(
[A]=".##.|#..#|####|#..#|#..#" [B]="###.|#..#|###.|#..#|###." [C]=".###|#...|#...|#...|.###"
[D]="###.|#..#|#..#|#..#|###." [E]="####|#...|###.|#...|####" [F]="####|#...|###.|#...|#..."
[G]=".###|#...|#.##|#..#|.###" [H]="#..#|#..#|####|#..#|#..#" [I]="###|.#.|.#.|.#.|###"
[J]="..##|...#|...#|#..#|.##." [K]="#..#|#.#.|##..|#.#.|#..#" [L]="#...|#...|#...|#...|####"
[M]="#...#|##.##|#.#.#|#...#|#...#" [N]="#...#|##..#|#.#.#|#..##|#...#" [O]=".##.|#..#|#..#|#..#|.##."
[P]="###.|#..#|###.|#...|#..." [Q]=".##.|#..#|#..#|#.#.|.#.#" [R]="###.|#..#|###.|#.#.|#..#"
[S]=".###|#...|.##.|...#|###." [T]="#####|..#..|..#..|..#..|..#.." [U]="#..#|#..#|#..#|#..#|.##."
[V]="#...#|#...#|#...#|.#.#.|..#.." [W]="#...#|#...#|#.#.#|##.##|#...#" [X]="#...#|.#.#.|..#..|.#.#.|#...#"
[Y]="#...#|.#.#.|..#..|..#..|..#.." [Z]="####|...#|.##.|#...|####"
[0]=".##.|#.##|##.#|#..#|.##." [1]=".#.|##.|.#.|.#.|###" [2]="###.|...#|.##.|#...|####"
[3]="###.|...#|.##.|...#|###." [4]="#..#|#..#|####|...#|...#" [5]="####|#...|###.|...#|###."
[6]=".##.|#...|###.|#..#|.##." [7]="####|...#|..#.|.#..|.#.." [8]=".##.|#..#|.##.|#..#|.##."
[9]=".##.|#..#|.###|...#|.##." [" "]="..|..|..|..|.." [-]="...|...|###|...|..." [.]=".|.|.|.|#"
[_]="....|....|....|....|####"
)
render_block_text() { # text -> LOGO_LINES
  local text="${1^^}" ch rows r i
  local -a out=("" "" "" "" "")
  local px="█"; [ "$UTF8" = 1 ] || px="#"
  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"; rows="${FONT[$ch]:-${FONT[" "]}}"
    IFS='|' read -ra parts <<<"$rows"
    for r in 0 1 2 3 4; do
      local p="${parts[r]}"; p="${p//#/$px}"; p="${p//./ }"
      out[r]+="$p "
    done
  done
  LOGO_LINES=("${out[@]}")
}
LOGO_LINES=(); LOGO_W=0
load_logo() {
  LOGO_LINES=()
  if [ -r "$TOOL_ROOT/logo.txt" ]; then mapfile -t LOGO_LINES < "$TOOL_ROOT/logo.txt"
  elif [ -n "$CL_LOGO" ]; then mapfile -t LOGO_LINES <<<"$CL_LOGO"
  else render_block_text "${CL_LOGO_TEXT:-${CL_TOOL_SHORT:-${CL_TOOL_NAME:-condaLauncher}}}"; fi
  # drop trailing blank lines
  while [ "${#LOGO_LINES[@]}" -gt 0 ] && [[ -z ${LOGO_LINES[-1]//[[:space:]]/} ]]; do unset 'LOGO_LINES[-1]'; done
  LOGO_W=0; local l; for l in "${LOGO_LINES[@]}"; do (( ${#l} > LOGO_W )) && LOGO_W=${#l}; done
}
_grad() { # i n -> colour escape for logo line i of n (vertical gradient)
  [ "$COLOR" = 1 ] || return 0
  local i=$1 n=$2
  if [ "$DEPTH" = 24 ] && [ -n "$G_FROM" ]; then
    local a b; IFS=';' read -ra a <<<"$G_FROM"; IFS=';' read -ra b <<<"$G_TO"
    local d=$(( n > 1 ? n - 1 : 1 ))
    printf '\033[38;2;%d;%d;%dm' $(( a[0] + (b[0]-a[0]) * i / d )) $(( a[1] + (b[1]-a[1]) * i / d )) $(( a[2] + (b[2]-a[2]) * i / d ))
  else
    if (( i * 2 < n )); then printf '%s' "$C_ACC"; else printf '%s' "$C_ACC2"; fi
  fi
}
# Logo + tagline as text lines (for the menu header and for printed screens).
header_lines() { # width -> HDR array
  local width="$1" i n
  HDR=()
  n=${#LOGO_LINES[@]}
  if (( LOGO_W > 0 && LOGO_W + 2 <= width )); then
    for ((i = 0; i < n; i++)); do HDR+=("  $(_grad "$i" "$n")${C_B}${LOGO_LINES[i]}${C_0}"); done
  else
    HDR+=("  ${C_REV}${C_B} ${CL_TOOL_SHORT:-${CL_TOOL_NAME:-condaLauncher}} ${C_0}")
  fi
  local nrun; nrun="$(count_running)"
  local tag="  ${C_B}${CL_TOOL_NAME:-condaLauncher template}${C_0} ${C_DIM}${G_DOTS} launcher v${CL_LAUNCHER_VERSION} ${G_DOTS} ${HOST} ${G_DOTS}${C_0} "
  if (( nrun > 0 )); then tag+="${C_OK}${G_DOT} ${nrun} running${C_0}"; else tag+="${C_DIM}${G_ODOT} none running${C_0}"; fi
  HDR+=("" "$tag")
}
print_header() { [ "$JSON" = 1 ] && return; [ "$RAW_ON" = 1 ] && _raw_off; local w=80; [ "$TTY_OK" = 1 ] && { _tty_size; w=$COLS; }; header_lines "$w"; printf '%s\n' "${HDR[@]}" ""; }

# ================================================================ output ====
REPORT=""; STEP_N=0; N_PASS=0; N_FAIL=0; N_WARN=0; T0_ACTION=0; T0_STEP=0; FAILS=(); FIXES=()
_ms() { local t="${EPOCHREALTIME:-}"; if [ -n "$t" ]; then t="${t/[.,]/}"; echo $(( t / 1000 )); else echo $(( $(NOW_EPOCH) * 1000 )); fi; }
_strip() { sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g; s/\x1b\\]8;;[^\x1b]*\x1b\\\\//g; s/\x1b\\][^\a]*\a//g'; }
out() { [ "$JSON" = 1 ] && return; [ "$RAW_ON" = 1 ] && _raw_off; printf '%s\n' "$*"; [ -n "$REPORT" ] && printf '%s\n' "$*" | _strip >> "$REPORT"; return 0; }
report_begin() { # action [version]
  STEP_N=0; N_PASS=0; N_FAIL=0; N_WARN=0; FAILS=(); FIXES=(); T0_ACTION="$(_ms)"
  mkdir -p "$RUN_DIR/reports" 2>/dev/null && _mode "$RUN_DIR" "$RUN_DIR/reports"
  REPORT="$RUN_DIR/reports/$(printf '%(%Y%m%d-%H%M%S)T' -1)_${1}${2:+_$2}@${HOST}.log"
  { : > "$REPORT"; } 2>/dev/null || REPORT=""
  [ -n "$REPORT" ] && _mode "$REPORT"
  # keep the newest CL_REPORT_KEEP
  local -a old=("$RUN_DIR"/reports/*.log)
  if (( ${#old[@]} > CL_REPORT_KEEP )); then
    printf '%s\n' "${old[@]}" | sort | head -n $(( ${#old[@]} - CL_REPORT_KEEP )) | while IFS= read -r f; do rm -f "$f"; done
  fi
}
section() { out ""; out "${C_ACC}${C_B}${G_DOTS}${G_DOTS} $1${C_0} ${C_DIM}$2${C_0}"; }
step_begin() { T0_STEP="$(_ms)"; }
_step_line() { # colour icon word name detail
  local n dots="" w name="$4" t
  printf -v n '%02d' $((++STEP_N))
  w=$(( 38 - ${#name} )); (( w < 2 )) && w=2
  printf -v dots '%*s' "$w" ''; dots="${dots// /.}"
  t=$(( $(_ms) - T0_STEP )); if (( t >= 1000 )); then t="$((t / 1000)).$(( (t % 1000) / 100 ))s"; else t="${t}ms"; fi
  out "[${n}] ${1}${3} ${2}${C_0}  ${name} ${C_DIM}${dots}${C_0} ${5}${5:+ }${C_DIM}${t}${C_0}"
  T0_STEP="$(_ms)"
}
pass() { N_PASS=$((N_PASS + 1)); _step_line "$C_OK" "PASS" "$G_OK" "$1" "${2:+${C_DIM}$2${C_0}}"; }
warn() { N_WARN=$((N_WARN + 1)); _step_line "$C_WARN" "WARN" "$G_WARN" "$1" "${2:+${C_WARN}$2${C_0}}"; [ -n "${3:-}" ] && hint "$3"; }
fail() { # name detail [fix] [output...]
  N_FAIL=$((N_FAIL + 1)); FAILS+=("$1"); _step_line "$C_ERR" "FAIL" "$G_FAIL" "$1" "${2:+${C_ERR}$2${C_0}}"
  local fix="${3:-}"; shift 3 2>/dev/null || shift $#
  local l; for l in "$@"; do out "      ${C_DIM}${G_PIPE} ${l}${C_0}"; done
  [ -n "$fix" ] && { out "      ${C_DIM}${G_TREE} fix:${C_0} ${fix}"; FIXES+=("$fix"); }
  return 0
}
hint() { out "      ${C_DIM}${G_TREE} $*${C_0}"; }
summary_box() { # title [extra lines...]
  local title="$1"; shift
  local total=$((N_PASS + N_FAIL + N_WARN)) el=$(( $(_ms) - T0_ACTION )) secs
  secs="$((el / 1000)).$(( (el % 1000) / 100 ))"
  local -a L=("${C_OK}${G_OK} ${N_PASS}/${total} PASS${C_0}   ${C_WARN}${G_WARN} ${N_WARN} WARN${C_0}   ${C_ERR}${G_FAIL} ${N_FAIL} FAIL${C_0}"
              "${G_CLOCK} ${secs} s" "$@")
  [ -n "$REPORT" ] && L+=("report: ${REPORT#$TOOL_ROOT/}")
  local w=${#title} l s
  for l in "${L[@]}"; do s="$(printf '%s' "$l" | _strip)"; (( ${#s} + 4 > w )) && w=$(( ${#s} + 4 )); done
  (( w < 44 )) && w=44
  local bar; printf -v bar '%*s' $(( w - ${#title} - 3 )) ''; bar="${bar// /$G_H}"
  out ""
  out "${G_TL}${G_H} ${C_B}${title}${C_0} ${bar}${G_TR}"
  for l in "${L[@]}"; do s="$(printf '%s' "$l" | _strip)"; printf -v bar '%*s' $(( w - ${#s} - 2 )) ''; out "${G_V}  ${l}${bar}${G_V}"; done
  printf -v bar '%*s' "$w" ''; out "${G_BL}${bar// /$G_H}${G_BR}"
}

# spinner: run a command in the background, animate on the terminal, return its status
SLEEP_FD=""
_nap() { if [ -z "$SLEEP_FD" ]; then exec {SLEEP_FD}<> <(:) 2>/dev/null || SLEEP_FD=-1; fi
         if [ "$SLEEP_FD" -ge 0 ] 2>/dev/null; then read -rt "$1" -u "$SLEEP_FD" _ 2>/dev/null; else sleep "$1"; fi; return 0; }
spin_run() { # message outfile cmd...
  local msg="$1" of="$2"; shift 2
  "$@" >"$of" 2>&1 & local pid=$! i=0 t0; t0="$(_ms)"
  if [ "$TTY_OK" = 1 ] && [ "$JSON" = 0 ]; then
    printf '\033[?25l' >&"$TTY"
    while kill -0 "$pid" 2>/dev/null; do
      local el=$(( ($(_ms) - t0) / 100 ))
      printf '\r\033[K  %s%s%s %s %s%d.%d s%s' "$C_ACC" "${G_SPIN[i % ${#G_SPIN[@]}]}" "$C_0" "$msg" "$C_DIM" $((el / 10)) $((el % 10)) "$C_0" >&"$TTY"
      i=$((i + 1)); _nap 0.1
    done
    printf '\r\033[K\033[?25h' >&"$TTY"
  fi
  wait "$pid"
}

# ============================================================ input / menu ==
KEY=""
_read_key() { # timeout(optional) -> KEY (and RAWKEY for the debug trace)
  local c ch rest t="${1:-}"
  RAWKEY=""
  if [ -n "$t" ]; then IFS= read -rsn1 -t "$t" -u "$TTY" c || { KEY=timeout; return 1; }
  else IFS= read -rsn1 -u "$TTY" c || { KEY=eof; return 1; }; fi
  RAWKEY="$c"
  case "$c" in
    $'\e')
      # over SSH the rest of a sequence can arrive a little later: wait 100 ms for the
      # byte after ESC (a lone ESC is a cancel), then 300 ms per byte inside a sequence
      if IFS= read -rsn1 -t 0.1 -u "$TTY" ch; then
        RAWKEY+="$ch"
        if [[ $ch == '[' || $ch == 'O' ]]; then
          rest=""
          while IFS= read -rsn1 -t 0.3 -u "$TTY" c; do rest+="$c"; [[ $c =~ [A-Za-z~] ]] && break; done
          RAWKEY+="$rest"
          case "$ch$rest" in
            '[A'|'OA') KEY=up ;; '[B'|'OB') KEY=down ;; '[C'|'OC') KEY=right ;; '[D'|'OD') KEY=left ;;
            '[H'|'OH'|'[1~'|'[7~') KEY=home ;; '[F'|'OF'|'[4~'|'[8~') KEY=end ;;
            '[5~') KEY=pgup ;; '[6~') KEY=pgdn ;;
            '[<'*[Mm]) KEY="mouse:${rest#<}" ;;                       # SGR 1006: ESC[<b;x;yM|m
            '[M')                                                     # X10 / normal: ESC[M + 3 raw bytes
              local cb cx cy b
              LC_ALL=C IFS= read -rsn1 -t 0.3 -d '' -u "$TTY" cb; LC_ALL=C IFS= read -rsn1 -t 0.3 -d '' -u "$TTY" cx
              LC_ALL=C IFS= read -rsn1 -t 0.3 -d '' -u "$TTY" cy
              printf -v cb '%d' "'$cb"; printf -v cx '%d' "'$cx"; printf -v cy '%d' "'$cy"
              b=$(( cb - 32 ))
              if (( (b & 3) == 3 && (b & 64) == 0 )); then
                if (( b & 32 )); then KEY="mouse:35;$((cx - 32));$((cy - 32))M"; else KEY="mouse:0;$((cx - 32));$((cy - 32))m"; fi
              else KEY="mouse:$b;$((cx - 32));$((cy - 32))M"; fi ;;
            *)
              if [[ $rest =~ ^([0-9]+)\;([0-9]+)\;([0-9]+)M$ ]]; then         # urxvt 1015: ESC[b;x;yM
                local b=$(( BASH_REMATCH[1] - 32 )) x="${BASH_REMATCH[2]}" y="${BASH_REMATCH[3]}"
                if (( (b & 3) == 3 && (b & 64) == 0 && (b & 32) == 0 )); then KEY="mouse:0;$x;${y}m"; else KEY="mouse:$b;$x;${y}M"; fi
              else KEY=unknown; fi ;;
          esac
        else KEY=esc; fi
      else KEY=esc; fi ;;
    ''|$'\n'|$'\r') KEY=enter ;;
    ' ') KEY=space ;;
    [0-9]) KEY="digit:$c" ;;
    *) KEY="char:$c" ;;
  esac
  [ -n "${CL_DEBUG_KEYS:-}" ] && printf '%s\t%q\n' "$KEY" "$RAWKEY" >> "$CL_DEBUG_KEYS"
  return 0
}
# Generic picker. Items are "label<TAB>hint<TAB>flags" (flags: d = disabled).
# Sets MENU_IDX. Returns 0 chosen, 1 cancelled, 2 no terminal.
# With multi=1: space toggles, a = all, Enter confirms; sets MENU_SEL (indices).
# Mouse: moving over a row highlights it; a click (press and release on the same row)
# chooses it -- or toggles it in a checklist. The wheel moves the highlight.
MENU_IDX=-1; MENU_SEL=()
menu_pick() { # title subtitle preselect multi items...
  local title="$1" sub="$2" cur="${3:-0}" multi="${4:-0}"; shift 4
  local -a items=("$@") lab hin dis sel
  local n=${#items[@]} i
  for ((i = 0; i < n; i++)); do
    IFS=$'\t' read -r "lab[i]" "hin[i]" "dis[i]" <<<"${items[i]}"; sel[i]=0
  done
  local labw=0; for ((i = 0; i < n; i++)); do (( ${#lab[i]} > labw )) && labw=${#lab[i]}; done
  for ((i = 0; i < n; i++)); do local _p; printf -v _p '%*s' $(( labw - ${#lab[i]} )) ''; [ -n "${hin[i]}" ] && lab[i]+="$_p"; done
  (( cur >= n || cur < 0 )) && cur=0
  # never preselect a disabled entry
  if [[ ${dis[cur]} == *d* ]]; then for ((i = 0; i < n; i++)); do [[ ${dis[i]} != *d* ]] && { cur=$i; break; }; done; fi
  if [ "$TTY_OK" != 1 ]; then _menu_fallback "$title" "$cur" "$multi" "${items[@]}"; return $?; fi
  local -a rowof=() hdr=(); local top=0 note="" pressed=-1 dirty=1 line
  _raw_on
  WINCHED=1
  while :; do
    if [ "$WINCHED" = 1 ]; then
      # size and header (which counts running servers) only when the window changes,
      # never per mouse event: motion reports arrive dozens of times a second
      local oldsz="${ROWS:-0}x${COLS:-0}"
      WINCHED=0; _tty_size; header_lines "$COLS"; hdr=("${HDR[@]}")
      [ "$oldsz" != "${ROWS}x${COLS}" ] && printf '\033[H\033[2J' >&"$TTY"
      PREV=(); dirty=1
    fi
    if [ "$dirty" = 1 ]; then
      FRAME=("${hdr[@]}" "" "  ${C_B}${title}${C_0}  ${C_DIM}${sub}${C_0}" "")
      local r=$(( ${#FRAME[@]} + 1 ))
      local avail=$(( ROWS - r - 2 )); (( avail < 3 )) && avail=3
      (( cur < top )) && top=$cur
      (( cur >= top + avail )) && top=$(( cur - avail + 1 ))
      rowof=()
      for ((i = top; i < n && i < top + avail; i++)); do
        local box="" style="" num=""
        (( i < 9 )) && num="$((i + 1))  " || num="   "
        [ "$multi" = 1 ] && { [ "${sel[i]}" = 1 ] && box="${C_OK}${G_BOXON}${C_0} " || box="${G_BOXOFF} "; }
        [[ ${dis[i]} == *d* ]] && style="$C_DIM"
        if (( i == cur )); then line="  ${C_OK}${G_PTR}${C_0} ${box}${C_B}${style}${num}${lab[i]}${C_0}"
        else line="    ${box}${C_DIM}${num}${lab[i]}${C_0}"; fi
        if [ -n "${hin[i]}" ]; then   # one screen row per item, or clicks land on the wrong row
          local h="${hin[i]}" room=$(( COLS - labw - 14 ))
          h="${h/#$HOME/\~}"
          (( room < 8 )) && h="" || { (( ${#h} > room )) && h="${G_ELL}${h: -$((room - 1))}"; }
          line+="   ${C_DIM}${h}${C_0}"
        fi
        FRAME+=("$line"); rowof[r]=$i; r=$((r + 1))
      done
      FRAME+=("")
      if [ -n "$note" ]; then FRAME+=("  ${C_WARN}${note}${C_0}")
      elif [ "$multi" = 1 ]; then FRAME+=("  ${C_DIM}${G_UPDN}/jk move ${G_DOTS} space or click toggle ${G_DOTS} a all ${G_DOTS} ${G_ENTER} confirm ${G_DOTS} q cancel${C_0}")
      else FRAME+=("  ${C_DIM}${G_UPDN}/jk move ${G_DOTS} ${G_ENTER} or click select ${G_DOTS} 1-$(( n < 9 ? n : 9 )) jump ${G_DOTS} q back${C_0}"); fi
      _frame_flush
      dirty=0; note=""
    fi
    _read_key 1 || { [ "$KEY" = timeout ] && continue; return 1; }
    dirty=1
    case "$KEY" in
      up|char:k|char:K) (( cur > 0 )) && cur=$((cur - 1)) || cur=$((n - 1)) ;;
      down|char:j|char:J) (( cur < n - 1 )) && cur=$((cur + 1)) || cur=0 ;;
      home) cur=0 ;; end) cur=$((n - 1)) ;;
      pgup) cur=$(( cur - 5 < 0 ? 0 : cur - 5 )) ;; pgdn) cur=$(( cur + 5 >= n ? n - 1 : cur + 5 )) ;;
      esc|char:q|char:Q) return 1 ;;
      space) [ "$multi" = 1 ] && [[ ${dis[cur]} != *d* ]] && sel[cur]=$(( 1 - sel[cur] )) ;;
      char:a|char:A) if [ "$multi" = 1 ]; then local any=0; for ((i = 0; i < n; i++)); do [[ ${dis[i]} != *d* && ${sel[i]} = 0 ]] && any=1; done
                       for ((i = 0; i < n; i++)); do [[ ${dis[i]} != *d* ]] && sel[i]=$any; done; fi ;;
      digit:*) local d="${KEY#digit:}"; if (( d >= 1 && d <= n )); then cur=$((d - 1))
                 if [ "$multi" = 1 ]; then [[ ${dis[cur]} != *d* ]] && sel[cur]=$(( 1 - sel[cur] ))
                 elif [[ ${dis[cur]} != *d* ]]; then MENU_IDX=$cur; return 0; else note="${lab[cur]}: not available"; fi; fi ;;
      enter)
        if [ "$multi" = 1 ]; then
          MENU_SEL=(); for ((i = 0; i < n; i++)); do [ "${sel[i]}" = 1 ] && MENU_SEL+=("$i"); done
          if [ "${#MENU_SEL[@]}" -eq 0 ] && [[ ${dis[cur]} != *d* ]]; then MENU_SEL=("$cur"); fi
          [ "${#MENU_SEL[@]}" -gt 0 ] && return 0; note="Nothing selected"
        elif [[ ${dis[cur]} == *d* ]]; then note="${lab[cur]}: ${hin[cur]:-not available}"
        else MENU_IDX=$cur; return 0; fi ;;
      mouse:*)
        local m kind b x y hit
        m="${KEY#mouse:}"; kind="${m: -1}"; m="${m%?}"; IFS=';' read -r b x y <<<"$m"
        hit="${rowof[y]:-}"
        if (( b == 64 )); then (( cur > 0 )) && cur=$((cur - 1))
        elif (( b == 65 )); then (( cur < n - 1 )) && cur=$((cur + 1))
        elif (( b & 32 )); then                                 # motion (35) or drag (32): hover
          if [ -n "$hit" ] && [ "$hit" != "$cur" ]; then cur=$hit; else dirty=0; fi
        elif (( (b & 3) == 0 )) && [ "$kind" = M ]; then        # left press: highlight, remember
          pressed="${hit:--1}"; [ -n "$hit" ] && cur=$hit || dirty=0
        elif (( (b & 3) == 0 )) && [ "$kind" = m ]; then        # left release on the pressed row: choose
          if [ -n "$hit" ] && { [ "$hit" = "$pressed" ] || [ "$pressed" = -1 ]; }; then
            cur=$hit; pressed=-1
            if [[ ${dis[cur]} == *d* ]]; then note="${lab[cur]}: ${hin[cur]:-not available}"
            elif [ "$multi" = 1 ]; then sel[cur]=$(( 1 - sel[cur] ))
            else MENU_IDX=$cur; return 0; fi
          else pressed=-1; dirty=0; fi
        else dirty=0; fi ;;
      *) dirty=0 ;;
    esac
  done
}
_menu_fallback() { # numbered prompt on a basic terminal; nothing at all without one
  local title="$1" cur="$2" multi="$3"; shift 3
  [ -t 0 ] || return 2
  local i lab hin dis ans
  echo; echo "$title"
  for ((i = 1; i <= $#; i++)); do IFS=$'\t' read -r lab hin dis <<<"${!i}"; printf '  %2d) %s%s\n' "$i" "$lab" "${hin:+   ($hin)}"; done
  if [ "$multi" = 1 ]; then
    read -rp "Numbers separated by spaces, 'a' for all, empty to cancel: " ans || return 1
    [ -z "$ans" ] && return 1
    MENU_SEL=(); if [ "$ans" = a ]; then for ((i = 0; i < $#; i++)); do MENU_SEL+=("$i"); done; return 0; fi
    for i in $ans; do [[ $i =~ ^[0-9]+$ ]] && (( i >= 1 && i <= $# )) && MENU_SEL+=("$((i - 1))"); done
    [ "${#MENU_SEL[@]}" -gt 0 ]; return $?
  fi
  read -rp "Choose 1-$# [$((cur + 1))], q to cancel: " ans || return 1
  [ "$ans" = q ] && return 1; [ -z "$ans" ] && ans=$((cur + 1))
  [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= $# )) || return 1
  IFS=$'\t' read -r lab hin dis <<<"${!ans}"; [[ $dis == *d* ]] && { echo "not available: $hin"; return 1; }
  MENU_IDX=$((ans - 1)); return 0
}
ask_yn() { # question default(y|n) -> 0 yes
  local q="$1" d="${2:-n}" a
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$RAW_ON" = 1 ] && _raw_off
  if [ "$TTY_OK" = 1 ]; then printf '  %s %s ' "$q" "$([ "$d" = y ] && echo '[Y/n]' || echo '[y/N]')" >&"$TTY"; IFS= read -r a <&"$TTY" || a=""
  elif [ -t 0 ]; then read -rp "  $q [y/N] " a || a=""
  else [ "$d" = y ]; return $?; fi
  [ -z "$a" ] && a="$d"; [[ $a == [yY]* ]]
}
ask_text() { # prompt default -> REPLY_TEXT
  local a; REPLY_TEXT="$2"; [ "$RAW_ON" = 1 ] && _raw_off
  if [ "$TTY_OK" = 1 ]; then printf '  %s [%s]: ' "$1" "$2" >&"$TTY"; IFS= read -r a <&"$TTY" || a=""
  elif [ -t 0 ]; then read -rp "  $1 [$2]: " a || a=""; fi
  [ -n "$a" ] && REPLY_TEXT="$a"; return 0
}

# ============================================================== versions ===
VERS=(); VERS_OK=(); VERS_WHY=()
discover_versions() {
  VERS=(); VERS_OK=(); VERS_WHY=()
  local d name
  local -a names=()
  for d in "$TOOL_ROOT"/$CL_VERSION_GLOB/; do names+=("$(basename "$d")"); done
  [ "${#names[@]}" -eq 0 ] && return 0
  mapfile -t names < <(printf '%s\n' "${names[@]}" | sort -rV)
  for name in "${names[@]}"; do
    d="$TOOL_ROOT/$name"
    VERS+=("$name")
    if [ -n "$CL_ENTRY" ] && [ ! -e "$d/$CL_ENTRY" ]; then VERS_OK+=(0); VERS_WHY+=("no entry point ($CL_ENTRY missing)")
    else VERS_OK+=(1); VERS_WHY+=(""); fi
  done
}
# Parse <version>/<CL_VERSION_ENV> (KEY=VALUE, never sourced) into V_<KEY> globals.
load_version() { # name
  local k v line f
  for k in "${!V_@}"; do unset "$k"; done
  VNAME="$1"; VDIR="$TOOL_ROOT/$1"; f="$VDIR/$CL_VERSION_ENV"
  if [ -r "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [[ $line =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
      k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
      v="${v%%+([[:space:]])#*}"; v="${v%"${v##*[![:space:]]}"}"
      if [[ $v == \"*\" || $v == \'*\' ]]; then v="${v:1:${#v}-2}"; fi
      printf -v "V_$k" '%s' "$v"
    done < "$f"
  fi
  V_ROLE="${V_ROLE:-}"; V_BANNER="${V_BANNER:-}"
  local idx=0 i; for i in "${!VERS[@]}"; do [ "${VERS[i]}" = "$1" ] && idx=$i; done
  V_PORT="${V_PORT:-$(( CL_PORT_DEFAULT + idx ))}"
  V_BIND="${V_BIND:-$CL_BIND_DEFAULT}"
}
version_index() { local i; for i in "${!VERS[@]}"; do [ "${VERS[i]}" = "$1" ] && { echo "$i"; return 0; }; done; return 1; }
last_used() { local f="$RUN_DIR/last@$HOST"; [ -r "$f" ] && head -n1 "$f"; }

# ================================================================= conda ===
FE=""; FE_KIND=""; CONDA_ROOT=""
find_frontend() {
  [ -n "$FE" ] && return 0
  local c root
  local -a cand=()
  [ -n "$SITE_CONDA" ] && cand+=("$SITE_CONDA")
  if [ -n "${CONDA_EXE:-}" ]; then cand+=("$(dirname "$CONDA_EXE")/mamba" "$CONDA_EXE"); fi
  for c in mamba conda micromamba; do local p; p="$(type -P "$c" 2>/dev/null)" && cand+=("$p"); done
  for root in /opt/miniconda /opt/miniconda3 /opt/conda /opt/miniforge3 /opt/mambaforge /opt/anaconda3 \
              "$HOME/miniconda3" "$HOME/miniforge3" "$HOME/mambaforge" "$HOME/anaconda3" "$HOME/miniconda" \
              /usr/local/miniconda3 /usr/local/conda; do
    cand+=("$root/bin/mamba" "$root/bin/conda")
  done
  cand+=("$HOME/.local/bin/micromamba" "$HOME/bin/micromamba")
  for c in "${cand[@]}"; do
    [ -x "$c" ] && [ -f "$c" ] || continue
    FE="$c"; FE_KIND="$(basename "$c")"
    case "$FE_KIND" in micromamba) CONDA_ROOT="${MAMBA_ROOT_PREFIX:-$HOME/micromamba}" ;; *) CONDA_ROOT="$(dirname "$(dirname "$c")")" ;; esac
    return 0
  done
  return 1
}
_condarc_envs_dirs() {
  local f
  for f in "${CONDARC:-}" "$HOME/.condarc" "$HOME/.config/conda/.condarc" "$HOME/.config/conda/condarc" "${CONDA_ROOT:+$CONDA_ROOT/.condarc}"; do
    [ -n "$f" ] && [ -r "$f" ] || continue
    awk '/^envs_dirs:/{f=1;next} f&&/^[[:space:]]*-/{sub(/^[[:space:]]*-[[:space:]]*/,"");gsub(/["'\'']/,"");print;next} f&&/^[^[:space:]]/{f=0}' "$f"
  done | sed "s|^~|$HOME|"
}
ENV_PREFIXES=(); ENV_NAMES=()
list_envs() { # union: bash scan + frontend list
  ENV_PREFIXES=(); ENV_NAMES=()
  find_frontend
  local -a raw=() ; local d p
  [ -r "$HOME/.conda/environments.txt" ] && mapfile -t -O "${#raw[@]}" raw < "$HOME/.conda/environments.txt"
  local -a dirs=(); mapfile -t dirs < <(_condarc_envs_dirs)
  for d in $SITE_ENV_DIRS; do dirs+=("$d"); done
  dirs+=("$HOME/.conda/envs" "${CONDA_ROOT:+$CONDA_ROOT/envs}" "${MAMBA_ROOT_PREFIX:+$MAMBA_ROOT_PREFIX/envs}")
  for d in "${dirs[@]}"; do [ -n "$d" ] && [ -d "$d" ] || continue; for p in "$d"/*/; do raw+=("${p%/}"); done; done
  [ -n "$CONDA_ROOT" ] && raw+=("$CONDA_ROOT")
  if [ -n "$FE" ]; then
    local js; js="$(timeout 20 "$FE" env list --json 2>/dev/null)"
    while IFS= read -r p; do [ -n "$p" ] && raw+=("$p"); done < <(printf '%s' "$js" | grep -o '"/[^"]*"' | tr -d '"')
  fi
  local -A seen=(); local rp
  for p in "${raw[@]}"; do
    [ -n "$p" ] && [ -d "$p/conda-meta" ] || continue
    rp="$(readlink -f "$p" 2>/dev/null || echo "$p")"
    [ -n "${seen[$rp]:-}" ] && continue; seen[$rp]=1
    ENV_PREFIXES+=("$p")
    if [ "$rp" = "$(readlink -f "$CONDA_ROOT" 2>/dev/null)" ]; then ENV_NAMES+=("base"); else ENV_NAMES+=("$(basename "$p")"); fi
  done
}
interp_of() { echo "$1/bin/$CL_INTERPRETER"; }
expected_env_name() { # from config, else environment.yml's name:
  [ -n "$CL_ENV_NAME" ] && { echo "$CL_ENV_NAME"; return; }
  local y; y="$(env_yml_path)"; [ -n "$y" ] && sed -n 's/^name:[[:space:]]*//p' "$y" | head -n1
}
env_yml_path() { local y; for y in $CL_ENV_YML; do [ -r "$VDIR/$y" ] && { echo "$VDIR/$y"; return; }; [ -r "$TOOL_ROOT/$y" ] && { echo "$TOOL_ROOT/$y"; return; }; done; }
env_lock_path() {
  local l; for l in $CL_ENV_LOCK; do [ -r "$VDIR/$l" ] && { echo "$VDIR/$l"; return; }; [ -r "$TOOL_ROOT/$l" ] && { echo "$TOOL_ROOT/$l"; return; }; done
  for l in "$VDIR"/deploy/*.lock.txt "$VDIR"/*.lock.txt; do grep -q '^@EXPLICIT' "$l" 2>/dev/null && { echo "$l"; return; }; done
}
recorded_env() { # for the loaded version, this host
  local f="$VDIR/$CL_ENV_RECORD"; [ -r "$f" ] || return 1
  local p; p="$(sed -n "s|^${HOST}\.prefix=||p" "$f" | tail -n1)"
  [ -n "$p" ] && [ -d "$p" ] && { echo "$p"; return 0; }
  return 1
}
record_env() { # prefix
  local f="$VDIR/$CL_ENV_RECORD" tmp
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  tmp="$(mktemp "$f.XXXXXX" 2>/dev/null)" || return 1
  { [ -r "$f" ] && grep -v -e "^${HOST}\.prefix=" -e '^default\.name=' "$f"
    [ -r "$f" ] || echo "# condaLauncher: conda env chosen per host (machine-specific; keep out of git)"
    echo "${HOST}.prefix=$1"; echo "default.name=$(basename "$1")"; } > "$tmp"
  mv -f "$tmp" "$f" && _mode "$f"
}
resolve_env_arg() { # NAME|PREFIX -> prefix
  local a="$1" i
  [ -d "$a/conda-meta" ] && { echo "$a"; return 0; }
  [ "${#ENV_PREFIXES[@]}" -eq 0 ] && list_envs
  for i in "${!ENV_NAMES[@]}"; do [ "${ENV_NAMES[i]}" = "$a" ] && { echo "${ENV_PREFIXES[i]}"; return 0; }; done
  return 1
}
# Interactive env picker for the loaded version. Sets ENV_PREFIX. 0 ok, 1 cancel, 3 create requested.
pick_env() {
  [ "${#ENV_PREFIXES[@]}" -eq 0 ] && spin_run "looking for conda environments" /dev/null true && list_envs
  local rec exp i pre=-1 hint
  rec="$(recorded_env)"; exp="$(expected_env_name)"
  local -a items=() idx=()
  for i in "${!ENV_PREFIXES[@]}"; do
    [ -x "$(interp_of "${ENV_PREFIXES[i]}")" ] || continue
    hint="${ENV_PREFIXES[i]}"
    if [ -n "$rec" ] && [ "$(readlink -f "$rec")" = "$(readlink -f "${ENV_PREFIXES[i]}")" ]; then hint="recorded for $VNAME on $HOST"; pre=${#items[@]}; fi
    if [ "$pre" -lt 0 ] && [ -n "$exp" ] && [ "${ENV_NAMES[i]}" = "$exp" ]; then hint="named in environment.yml"; pre=${#items[@]}; fi
    items+=("${ENV_NAMES[i]}"$'\t'"$hint"$'\t'); idx+=("$i")
  done
  [ "$pre" -lt 0 ] && pre=0
  items+=("+ Create a new environment"$'\t'"from $(basename "$(env_lock_path 2>/dev/null || true)" 2>/dev/null || echo lockfile) / environment.yml"$'\t')
  menu_pick "Conda environment for $VNAME" "($(( ${#items[@]} - 1 )) with $CL_INTERPRETER)" "$pre" 0 "${items[@]}" || return 1
  if (( MENU_IDX == ${#items[@]} - 1 )); then return 3; fi
  ENV_PREFIX="${ENV_PREFIXES[${idx[MENU_IDX]}]}"; return 0
}
is_shared_env() { local n; for n in $SITE_SHARED_ENVS; do [ "$n" = "$(basename "$1")" ] && return 0; done; return 1; }

# Package checks: ONE interpreter call checks everything and prints
#   PASS<TAB>name<TAB>version<TAB>ms   or   FAIL<TAB>name<TAB>reason
read -r -d '' PY_CHECK <<'PYEOF'
import sys, time, re, importlib, importlib.metadata as md
def vt(s): return tuple(int(x) for x in re.findall(r'\d+', s)[:4])
for spec in sys.argv[1:]:
    m = re.match(r'^([A-Za-z0-9_.]+)(?::([A-Za-z0-9_.\-]+))?(?:(>=|<=|==|>|<)(.+))?$', spec)
    if not m: print(f"FAIL\t{spec}\tunreadable requirement"); continue
    imp, dist, op, want = m.groups(); t = time.time()
    try: mod = importlib.import_module(imp)
    except Exception as e: print(f"FAIL\t{imp}\t{type(e).__name__}: {e}".replace("\n", " ")); continue
    try: v = md.version(dist or imp)
    except Exception: v = str(getattr(mod, "__version__", "?"))
    if op and v != "?":
        a, b = vt(v), vt(want)
        ok = {">=": a >= b, "<=": a <= b, "==": a == b, ">": a > b, "<": a < b}[op]
        if not ok: print(f"FAIL\t{imp}\tversion {v}, need {op}{want}"); continue
    print(f"PASS\t{imp}\t{v}\t{int((time.time()-t)*1000)}")
PYEOF
read -r -d '' R_CHECK <<'REOF'
a <- setdiff(commandArgs(TRUE), "--args")
for (s in a) {
  m <- regmatches(s, regexec("^([A-Za-z0-9.]+)(>=|<=|==|>|<)?(.*)$", s))[[1]]
  if (length(m) == 0) { cat("FAIL\t", s, "\tunreadable requirement\n", sep = ""); next }
  p <- m[2]; op <- m[3]; want <- m[4]; t <- proc.time()[[3]]
  ok <- suppressWarnings(suppressMessages(requireNamespace(p, quietly = TRUE)))
  if (!ok) { cat("FAIL\t", p, "\tnot installed or fails to load\n", sep = ""); next }
  v <- as.character(utils::packageVersion(p))
  if (nzchar(op)) {
    c <- utils::compareVersion(v, want)
    good <- switch(op, ">=" = c >= 0, "<=" = c <= 0, "==" = c == 0, ">" = c > 0, "<" = c < 0)
    if (!good) { cat("FAIL\t", p, "\tversion ", v, ", need ", op, want, "\n", sep = ""); next }
  }
  cat("PASS\t", p, "\t", v, "\t", round((proc.time()[[3]] - t) * 1000), "\n", sep = "")
}
REOF
MISSING_PKGS=()
check_packages() { # prefix ; emits PASS/FAIL steps
  local pre="$1" tmp st name a b c
  MISSING_PKGS=()
  local lang="" ; local -a specs=()
  if [ -n "$CL_REQUIRE_R" ]; then lang=R; read -ra specs <<<"$CL_REQUIRE_R"; fi
  if [ -n "$CL_REQUIRE_PY" ]; then lang=PY; read -ra specs <<<"$CL_REQUIRE_PY"; fi
  [ "${#specs[@]}" -eq 0 ] && { pass "packages" "none declared in the config"; return 0; }
  tmp="$(mktemp)"
  if [ "$lang" = R ]; then
    [ -x "$pre/bin/Rscript" ] || { fail "R packages" "no Rscript in $pre"; rm -f "$tmp"; return 1; }
    spin_run "loading ${#specs[@]} R packages (the slowest check)" "$tmp" env PATH="$pre/bin:$PATH" LANG=C.UTF-8 "$pre/bin/Rscript" --vanilla -e "$R_CHECK" --args "${specs[@]}"
  else
    [ -x "$pre/bin/python" ] || { fail "Python packages" "no python in $pre"; rm -f "$tmp"; return 1; }
    spin_run "importing ${#specs[@]} Python packages" "$tmp" env PATH="$pre/bin:$PATH" "$pre/bin/python" -c "$PY_CHECK" "${specs[@]}"
  fi
  local seen=0
  while IFS=$'\t' read -r st name a b; do
    case "$st" in
      PASS) seen=$((seen + 1)); T0_STEP=$(( $(_ms) - ${b:-0} )); pass "$([ "$lang" = R ] && echo "R" || echo "py") $name" "$a" ;;
      FAIL) seen=$((seen + 1)); T0_STEP="$(_ms)"; MISSING_PKGS+=("$name")
            local cp; if [ "$lang" = R ]; then cp="r-${name,,}"; else cp="$name"; fi
            fail "$([ "$lang" = R ] && echo "R" || echo "py") $name" "$a" "${FE:-mamba} install -p $pre -c conda-forge $cp" ;;
    esac
  done < "$tmp"
  if [ "$seen" -eq 0 ]; then
    local -a tail_l=(); mapfile -t tail_l < <(tail -n 10 "$tmp")
    fail "package check" "the interpreter did not run" "" "${tail_l[@]}"
  fi
  rm -f "$tmp"
}
offer_install() { # prefix
  [ "${#MISSING_PKGS[@]}" -gt 0 ] || return 0
  find_frontend || return 0
  if is_shared_env "$1"; then hint "$(basename "$1") is listed as shared in site.env: install by hand if you are sure."; return 0; fi
  # installing changes an env other tools may share: only on an explicit --install,
  # or a y typed at the terminal. --yes alone never installs anything.
  local -a cp=(); local p
  for p in "${MISSING_PKGS[@]}"; do if [ -n "$CL_REQUIRE_R" ]; then cp+=("r-${p,,}"); else cp+=("$p"); fi; done
  if [ "${OPT_INSTALL:-0}" != 1 ]; then
    [ "$TTY_OK" = 1 ] || { hint "to install them: re-run with --install, or run the fix lines above"; return 0; }
    out ""
    local saved="$ASSUME_YES"; ASSUME_YES=0
    ask_yn "Install the ${#cp[@]} missing package(s) into $(basename "$1") now (${cp[*]})?" n || { ASSUME_YES="$saved"; return 0; }
    ASSUME_YES="$saved"
  fi
  "$FE" install -y -p "$1" -c conda-forge -c bioconda "${cp[@]}" 2>&1 | tee -a "${REPORT:-/dev/null}"
}
create_env() { # -> ENV_PREFIX on success
  find_frontend || { fail "conda frontend" "no mamba/conda/micromamba found" "install miniforge, or set CONDA=/path/to/mamba in ~/.config/condaLauncher/site.env"; return 1; }
  local lock yml name src
  lock="$(env_lock_path)"; yml="$(env_yml_path)"
  ask_text "Name for the new environment" "$(expected_env_name || true)"; name="${REPLY_TEXT:-${CL_TOOL_SHORT}_env}"
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { fail "env name" "'$name' is not a valid name"; return 1; }
  if [ -n "$lock" ] && [ "$(uname -m)" = x86_64 ] && grep -q 'linux-64' "$lock"; then src=lock
  elif [ -n "$yml" ]; then src=yml
  else fail "env source" "no lockfile or environment.yml for $VNAME" "add environment.yml to $VNAME/ or deploy/"; return 1; fi
  local -a cmd plan
  if [ "$src" = lock ]; then
    cmd=("$FE" create -y -n "$name" --file "$lock")
    out "  ${C_B}Will create${C_0} $name ${C_DIM}from the lockfile${C_0} ${lock#$TOOL_ROOT/}"
    out "  $(grep -c '^http' "$lock") packages, exact builds, no solving needed"
  else
    cmd=("$FE" env create -y -n "$name" -f "$yml")
    out "  ${C_B}Will create${C_0} $name ${C_DIM}from${C_0} ${yml#$TOOL_ROOT/} ${C_DIM}(solving: dry run first)${C_0}"
    local tmp; tmp="$(mktemp)"
    spin_run "solving environment (dry run)" "$tmp" "$FE" env create -n "$name" -f "$yml" --dry-run
    mapfile -t plan < <(tail -n 15 "$tmp"); rm -f "$tmp"
    local l; for l in "${plan[@]}"; do out "    ${C_DIM}${l}${C_0}"; done
  fi
  out "  ${C_DIM}command: ${cmd[*]}${C_0}"
  ask_yn "Proceed?" n || { warn "create env" "cancelled"; return 1; }
  mkdir -p "$RUN_DIR" 2>/dev/null
  local lockfd; exec {lockfd}>"$RUN_DIR/.create-$name@$HOST.lock"
  flock -w 5 "$lockfd" 2>/dev/null || { fail "create env" "another launcher is creating $name"; return 1; }
  step_begin
  if "${cmd[@]}" 2>&1 | tee -a "${REPORT:-/dev/null}"; then
    ENV_PREFIX="$(resolve_env_arg "$name" || true)"; list_envs; ENV_PREFIX="$(resolve_env_arg "$name" || true)"
    if [ -n "$ENV_PREFIX" ]; then
      pass "create env $name" "$ENV_PREFIX"
      if [ "$src" = yml ]; then
        local lf="$RUN_DIR/$name.lock.txt"
        { "$FE" list -p "$ENV_PREFIX" --explicit > "$lf"; } 2>/dev/null && _mode "$lf" && hint "lockfile written: ${lf#$TOOL_ROOT/} (move it beside environment.yml to reuse)"
      fi
      return 0
    fi
  fi
  fail "create env $name" "the package manager reported an error (see the report)"; return 1
}

# ======================================================= processes/state ===
state_file() { echo "$RUN_DIR/$1@${2:-$HOST}.state"; }
# parse a state file into ST_* (never sourced: the folder may be world-writable)
read_state() {
  local k v line
  for k in "${!ST_@}"; do unset "$k"; done
  [ -r "$1" ] || return 1
  while IFS= read -r line; do
    [[ $line =~ ^([a-z_]+)=(.*)$ ]] || continue
    printf -v "ST_${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
  done < "$1"
  return 0
}
_starttime() { local l; read -r l < "/proc/$1/stat" 2>/dev/null || return 1; l="${l##*) }"; local -a f; read -ra f <<<"$l"; echo "${f[19]}"; }
# STATE: running | stale | other-host | gone
state_status() { # file -> STATE
  read_state "$1" || { STATE=gone; return; }
  if [ "${ST_host:-}" != "$HOST" ]; then STATE=other-host; return; fi
  local p="${ST_pid:-}"
  [[ $p =~ ^[0-9]+$ ]] && [ -d "/proc/$p" ] || { STATE=stale; return; }
  [ "$(stat -c %u "/proc/$p" 2>/dev/null)" = "$(id -u)" ] || { STATE=stale; return; }
  [ "$(_starttime "$p")" = "${ST_starttime:-x}" ] || { STATE=stale; return; }
  STATE=running
}
count_running() { local f n=0; for f in "$RUN_DIR"/*@"$HOST".state; do state_status "$f"; [ "$STATE" = running ] && n=$((n + 1)); done; echo "$n"; }
port_busy() { # port -> 0 busy
  if command -v ss >/dev/null 2>&1; then [ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ]; return $?; fi
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}
port_owner() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*",pid=[0-9]*' | head -n1 | sed 's/users:(("\(.*\)",pid=\([0-9]*\)/\1 pid \2/'; }
port_claimed() { local f; for f in "$RUN_DIR"/*@"$HOST".state; do read_state "$f" && [ "${ST_port:-}" = "$1" ] && [ "$f" != "$2" ] && return 0; done; return 1; }
http_code() { # host port path -> prints status code or 000
  local r
  r="$(timeout 4 bash -c 'exec 3<>"/dev/tcp/$1/$2" || exit 1; printf "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n" "$3" "$1" >&3; IFS= read -r l <&3; printf "%s" "$l"' _ "$1" "$2" "$3" 2>/dev/null)"
  [[ $r =~ ^HTTP/[0-9.]+\ ([0-9]{3}) ]] && echo "${BASH_REMATCH[1]}" || echo 000
}
probe_host() { case "$1" in 0.0.0.0|""|::) echo 127.0.0.1 ;; *) echo "$1" ;; esac; }
lan_ips() { hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.'; }
_link() { # url -> clickable when supported
  if [ "$COLOR" = 1 ] && [ "$TTY_OK" = 1 ] && [ "${TERM:-}" != linux ] && [ -z "${CL_NO_LINKS:-}" ]; then
    printf '\033]8;;%s\033\\%s%s%s\033]8;;\033\\' "$1" "$C_LINK" "$1" "$C_0"
  else printf '%s' "$1"; fi
}
_fmt_dur() { local s=$1; if ((s >= 86400)); then echo "$((s / 86400))d$(((s % 86400) / 3600))h"; elif ((s >= 3600)); then echo "$((s / 3600))h$(((s % 3600) / 60))m"; elif ((s >= 60)); then echo "$((s / 60))m$((s % 60))s"; else echo "${s}s"; fi; }
rotate_log() { # file
  local f="$1" i
  [ -e "$f" ] || return 0
  for ((i = CL_LOG_KEEP - 1; i >= 1; i--)); do [ -e "$f.$i" ] && mv -f "$f.$i" "$f.$((i + 1))"; done
  mv -f "$f" "$f.1"; rm -f "$f.$((CL_LOG_KEEP + 1))"
}
take_lock() {
  mkdir -p "$RUN_DIR" 2>/dev/null; _mode "$RUN_DIR"
  command -v flock >/dev/null 2>&1 || return 0
  exec {LOCK_FD}>"$RUN_DIR/.lock@$HOST" 2>/dev/null || return 0
  _mode "$RUN_DIR/.lock@$HOST"
  flock -n "$LOCK_FD" && return 0
  out "  ${C_DIM}another launcher is busy on this tool; waiting up to 30 s ${G_ELL}${C_0}"
  flock -w 30 "$LOCK_FD"
}
subst() { # string -> placeholders replaced
  local s="$1"
  s="${s//\{INTERP\}/$INTERP}"; s="${s//\{PY\}/$INTERP}"; s="${s//\{RSCRIPT\}/$INTERP}"
  s="${s//\{PORT\}/$PORT}"; s="${s//\{BIND\}/$BIND}"; s="${s//\{VDIR\}/$VDIR}"; s="${s//\{PREFIX\}/$ENV_PREFIX}"
  s="${s//\{VERSION\}/$VNAME}"; s="${s//\{TOOL\}/${CL_TOOL_NAME}}"; s="${s//\{HOST\}/$HOST}"
  s="${s//\{DATE\}/$(printf '%(%Y-%m-%d)T' -1)}"; s="${s//\{ENTRY\}/$CL_ENTRY}"
  printf '%s' "$s"
}

# ============================================================== actions ====
# ---- preflight (also the first half of start) ------------------------------
# Needs: VNAME/VDIR loaded, ENV_PREFIX set. Sets PORT, BIND.
run_checks() { # mode: preflight|start
  local mode="$1" f c
  section "Version" "$VNAME"
  step_begin
  local vi; vi="$(version_index "$VNAME")"
  if [ -n "$vi" ] && [ "${VERS_OK[vi]}" = 1 ]; then pass "version folder $VNAME" "${CL_ENTRY:-launchable}"
  else fail "version folder $VNAME" "${VERS_WHY[vi]:-not found}" "check $TOOL_ROOT/$VNAME"; fi
  step_begin
  if [ -r "$VDIR/$CL_VERSION_ENV" ]; then pass "version settings" "${CL_VERSION_ENV} role=${V_ROLE:-?} port=$V_PORT"
  else warn "version settings" "no $CL_VERSION_ENV: using port $V_PORT, no role"; fi
  if [ "${V_ROLE:-}" = dev ] && [ -z "$BANNER" ] && [ "$mode" = start ]; then
    step_begin; warn "dev banner" "ROLE=dev but no banner: it will look like production"
  fi

  section "Conda environment" "$(basename "$ENV_PREFIX")"
  step_begin
  if find_frontend; then pass "package manager" "$FE_KIND ($FE)"; else warn "package manager" "none found (only needed to create envs)"; fi
  step_begin
  INTERP="$(interp_of "$ENV_PREFIX")"
  if [ -x "$INTERP" ]; then pass "interpreter" "$INTERP"
  else fail "interpreter" "no $CL_INTERPRETER in $ENV_PREFIX" "pick another env, or: ${FE:-mamba} install -p $ENV_PREFIX ${CL_INTERPRETER/Rscript/r-base}"; fi
  check_packages "$ENV_PREFIX"
  for c in $CL_REQUIRE_CMDS; do
    step_begin
    if PATH="$ENV_PREFIX/bin:$PATH" type -P "$c" >/dev/null 2>&1; then pass "command $c" "$(PATH="$ENV_PREFIX/bin:$PATH" type -P "$c")"
    else fail "command $c" "not found in the env or on PATH" "${FE:-mamba} install -p $ENV_PREFIX -c conda-forge $c"; fi
  done

  section "Files" "inside $VNAME/"
  for f in $CL_REQUIRE_FILES ${CL_ENTRY}; do
    step_begin
    if [ -e "$VDIR/$f" ]; then pass "file $f"; else fail "file $f" "missing" "restore $VNAME/$f"; fi
  done
  step_begin
  if mkdir -p "$RUN_DIR" 2>/dev/null && [ -w "$RUN_DIR" ]; then pass "run folder writable" "${RUN_DIR#$TOOL_ROOT/}/"
  else fail "run folder writable" "$RUN_DIR" "check permissions of $TOOL_ROOT"; fi

  section "Network" "port and address"
  BIND="${OPT_BIND:-$V_BIND}"; PORT="${OPT_PORT:-$V_PORT}"
  local sf; sf="$(state_file "$VNAME")"
  state_status "$sf"
  step_begin
  if [ "$STATE" = running ]; then
    if [ "$mode" = start ]; then fail "already running" "$VNAME is up on port ${ST_port} (pid ${ST_pid})" "stop it first: $(basename "$SELF") stop --version $VNAME"
    else pass "already running" "$VNAME on port ${ST_port} (pid ${ST_pid})"; fi
  else pass "not running yet" "$VNAME"; fi
  if [ "$STATE" != running ]; then
    step_begin
    if port_busy "$PORT" || port_claimed "$PORT" "$sf"; then
      local who; who="$(port_owner "$PORT")"
      local p2=$((PORT + 1)) lim=$((PORT + CL_PORT_SCAN))
      while (( p2 <= lim )) && { port_busy "$p2" || port_claimed "$p2" "$sf"; }; do p2=$((p2 + 1)); done
      if [ -n "${OPT_PORT:-}" ]; then fail "port $PORT" "busy${who:+ ($who)}" "choose another with --port"
      elif (( p2 <= lim )); then warn "port $PORT" "busy${who:+ ($who)} ${G_ARR} using $p2"; PORT=$p2
      else fail "port $PORT" "busy, and no free port up to $lim"; fi
    else pass "port $PORT free"; fi
  fi
  step_begin
  if [ "$BIND" = 0.0.0.0 ]; then warn "bind $BIND" "whole network, no login: anyone on the LAN can open it" "this machine only: --local"
  else pass "bind $BIND"; fi
}

# ---- Start -------------------------------------------------------------------
choose_version() { # purpose -> VNAME loaded; 0 ok 1 cancel
  discover_versions
  [ "${#VERS[@]}" -gt 0 ] || { out "  ${C_ERR}No version folders ($CL_VERSION_GLOB) in $TOOL_ROOT${C_0}"; return 1; }
  if [ -n "${OPT_VERSION:-}" ]; then
    version_index "$OPT_VERSION" >/dev/null || { out "  ${C_ERR}No version '$OPT_VERSION'. Found: ${VERS[*]}${C_0}"; return 1; }
    load_version "$OPT_VERSION"; return 0
  fi
  local last pre=0 i; last="$(last_used)"
  local -a items=()
  for i in "${!VERS[@]}"; do
    load_version "${VERS[i]}"
    local h="${V_ROLE:-   }"; h="$(printf '%-4s :%s' "$h" "$V_PORT")"
    state_status "$(state_file "${VERS[i]}")"; [ "$STATE" = running ] && h+="  ${G_DOT} running"
    [ "${VERS[i]}" = "$last" ] && { h+="  (last started)"; pre=$i; }
    if [ "${VERS_OK[i]}" = 1 ]; then items+=("${VERS[i]}"$'\t'"$h"$'\t'); else items+=("${VERS[i]}"$'\t'"${G_FAIL} ${VERS_WHY[i]}"$'\t'd); fi
  done
  if [ "$TTY_OK" != 1 ] && ! [ -t 0 ] || [ "$ASSUME_YES" = 1 ]; then
    for i in "${!VERS[@]}"; do [ "${VERS_OK[i]}" = 1 ] && [ "$i" = "$pre" ] && { load_version "${VERS[i]}"; return 0; }; done
    for i in "${!VERS[@]}"; do [ "${VERS_OK[i]}" = 1 ] && { load_version "${VERS[i]}"; return 0; }; done; return 1
  fi
  menu_pick "$1" "${#VERS[@]} version(s) found in $(basename "$TOOL_ROOT")/" "$pre" 0 "${items[@]}" || return 1
  load_version "${VERS[MENU_IDX]}"
}
choose_env() { # -> ENV_PREFIX; 0 ok 1 cancel/fail
  if [ -n "${OPT_ENV:-}" ]; then
    ENV_PREFIX="$(resolve_env_arg "$OPT_ENV")" || { out "  ${C_ERR}No conda env '$OPT_ENV'${C_0}"; return 1; }; return 0
  fi
  if [ "$TTY_OK" != 1 ] && ! [ -t 0 ] || [ "$ASSUME_YES" = 1 ]; then
    ENV_PREFIX="$(recorded_env)" && return 0
    list_envs; local e; e="$(expected_env_name)"
    [ -n "$e" ] && ENV_PREFIX="$(resolve_env_arg "$e")" && return 0
    out "  ${C_ERR}No env recorded for $VNAME on $HOST: pass --env NAME${C_0}"; return 1
  fi
  local rc; pick_env; rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 3 ]; then report_begin create-env "$VNAME"; section "Create environment" "for $VNAME"; create_env && return 0; fi
  return 1
}
choose_banner() { # -> BANNER
  local def=n; [ "${V_ROLE:-}" = dev ] && def=y
  local text="${V_BANNER:-$(subst "$CL_BANNER_TEMPLATE")}"
  case "${OPT_BANNER:-}" in
    on|yes|1) BANNER="$text"; return 0 ;; off|no|0) BANNER=""; return 0 ;;
    "") ;; *) BANNER="$OPT_BANNER"; return 0 ;;
  esac
  if [ "$TTY_OK" != 1 ] && ! [ -t 0 ] || [ "$ASSUME_YES" = 1 ]; then [ "$def" = y ] && BANNER="$text" || BANNER=""; return 0; fi
  local -a items=("Yes, show the banner"$'\t'"\"$text\""$'\t' "No banner"$'\t'"looks like production"$'\t')
  local pre=1; [ "$def" = y ] && pre=0
  menu_pick "Development banner for $VNAME?" "recommended: $([ "$def" = y ] && echo "yes, ROLE=dev" || echo "no, ROLE=${V_ROLE:-not set}")" "$pre" 0 "${items[@]}" || return 1
  if [ "$MENU_IDX" = 0 ]; then BANNER="$text"; else BANNER=""; fi
}
action_start() {
  choose_version "Start which version?" || return 1
  choose_env || return 1
  choose_banner || return 1
  [ "$TTY_OK" = 1 ] && _raw_off
  report_begin start "$VNAME"
  print_header
  out "  ${C_B}Start${C_0} $VNAME ${C_DIM}env${C_0} $(basename "$ENV_PREFIX") ${C_DIM}banner${C_0} ${BANNER:-off}"
  take_lock || { out "  ${C_ERR}Gave up waiting for the other launcher.${C_0}"; return 1; }
  run_checks start
  if [ "$N_FAIL" -gt 0 ]; then
    offer_install "$ENV_PREFIX"
    summary_box "Start $VNAME: NOT started" "${N_FAIL} check(s) failed: ${FAILS[*]}"; _title "${G_FAIL} $CL_TOOL_SHORT: start failed"; return 1
  fi
  section "Launch" "detached: keeps running after this window closes"
  local sf log pidf; sf="$(state_file "$VNAME")"; log="$RUN_DIR/$VNAME@$HOST.log"; pidf="$RUN_DIR/.$VNAME@$HOST.pid"
  step_begin
  rotate_log "$log"; : > "$log"; _mode "$log"; rm -f "$pidf"
  local -a cmd=(); local a; for a in "${CL_CMD[@]}"; do cmd+=("$(subst "$a")"); done
  (
    cd "$VDIR" || exit 1
    # the server must not inherit our lock, terminal or timer descriptors: a held
    # lock would block every later launcher run for as long as the server lives
    [ -n "${LOCK_FD:-}" ] && exec {LOCK_FD}>&-
    [ -n "$TTY" ] && exec {TTY}>&-
    [ -n "$SLEEP_FD" ] && [ "$SLEEP_FD" -ge 0 ] 2>/dev/null && exec {SLEEP_FD}>&-
    export PATH="$ENV_PREFIX/bin:$PATH" CONDA_PREFIX="$ENV_PREFIX"
    export LANG="${LANG:-C.UTF-8}"; case "${LANG}" in *[Uu][Tt][Ff]*) ;; *) export LANG=C.UTF-8 ;; esac
    [ -d "$ENV_PREFIX/lib/jvm" ] && export JAVA_HOME="$ENV_PREFIX/lib/jvm"
    [ -d "$ENV_PREFIX/share/gdal" ] && export GDAL_DATA="$ENV_PREFIX/share/gdal"
    [ -d "$ENV_PREFIX/share/proj" ] && export PROJ_DATA="$ENV_PREFIX/share/proj" PROJ_LIB="$ENV_PREFIX/share/proj"
    [ -d "$ENV_PREFIX/share/glib-2.0/schemas" ] && export GSETTINGS_SCHEMA_DIR="$ENV_PREFIX/share/glib-2.0/schemas"
    export CL_BANNER="$BANNER" CL_ROLE="${V_ROLE:-}" CL_VERSION="$VNAME" CL_PORT="$PORT" CL_BIND="$BIND" \
           CL_VDIR="$VDIR" CL_ENV_PREFIX="$ENV_PREFIX" CL_TOOL="$CL_TOOL_NAME" CL_HOST="$HOST"
    if declare -F cl_tool_env >/dev/null; then cl_tool_env || exit 1; fi
    echo "=== $(date '+%F %T') condaLauncher start $VNAME port $PORT: ${cmd[*]}" >>"$log"
    exec setsid -f bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$pidf" "${cmd[@]}" >>"$log" 2>&1 </dev/null
  )
  local i pid=""
  for ((i = 0; i < 50; i++)); do [ -s "$pidf" ] && { pid="$(<"$pidf")"; break; }; _nap 0.1; done
  if ! [[ $pid =~ ^[0-9]+$ ]]; then local -a tl; mapfile -t tl < <(tail -n 10 "$log"); fail "launch" "the process did not start" "" "${tl[@]}"; summary_box "Start $VNAME: FAILED"; return 1; fi
  rm -f "$pidf"
  local st; st="$(_starttime "$pid")"
  { echo "pid=$pid"; echo "starttime=$st"; echo "host=$HOST"; echo "user=$(id -un)"; echo "version=$VNAME"
    echo "port=$PORT"; echo "bind=$BIND"; echo "env=$ENV_PREFIX"; echo "banner=$BANNER"; echo "role=${V_ROLE:-}"
    echo "started=$(NOW_EPOCH)"; echo "log=$log"; echo "cmd=${cmd[*]}"; } > "$sf"; _mode "$sf"
  pass "launch" "pid $pid (process group $pid)"
  record_env "$ENV_PREFIX" && { echo "$VNAME" > "$RUN_DIR/last@$HOST"; _mode "$RUN_DIR/last@$HOST"; }
  # health
  step_begin
  local ph code=000 t0 limit; ph="$(probe_host "$BIND")"; t0="$(NOW_EPOCH)"; limit="${OPT_TIMEOUT:-$CL_START_TIMEOUT}"
  local spin=0 died=0
  [ "$TTY_OK" = 1 ] && printf '\033[?25l' >&"$TTY"
  while :; do
    code="$(http_code "$ph" "$PORT" "$CL_HEALTH_PATH")"
    [[ $code =~ ^[23] ]] && break
    kill -0 "$pid" 2>/dev/null || { died=1; break; }
    (( $(NOW_EPOCH) - t0 >= limit )) && break
    if [ "$TTY_OK" = 1 ]; then printf '\r\033[K  %s%s%s waiting for HTTP on %s:%s%s %s%ds / %ds%s' "$C_ACC" "${G_SPIN[spin % ${#G_SPIN[@]}]}" "$C_0" "$ph" "$PORT" "$CL_HEALTH_PATH" "$C_DIM" $(( $(NOW_EPOCH) - t0 )) "$limit" "$C_0" >&"$TTY"; fi
    spin=$((spin + 1)); _nap 0.25
  done
  [ "$TTY_OK" = 1 ] && printf '\r\033[K\033[?25h' >&"$TTY"
  local el=$(( $(NOW_EPOCH) - t0 ))
  if [[ $code =~ ^[23] ]]; then pass "HTTP $code on $CL_HEALTH_PATH" "after ${el} s"
  else
    local -a tl; mapfile -t tl < <(tail -n 10 "$log")
    if [ "$died" = 1 ]; then fail "server process" "exited during startup" "read the log: ${log#$TOOL_ROOT/}" "${tl[@]}"; rm -f "$sf"
    else fail "health" "no answer within ${limit} s (process still running, pid $pid)" "wait and run Diagnostics, or raise CL_START_TIMEOUT" "${tl[@]}"; fi
    summary_box "Start $VNAME: NOT healthy"; _title "${G_FAIL} $CL_TOOL_SHORT: start failed"; return 1
  fi
  local sz; sz=$(( $(stat -c %s "$log.1" 2>/dev/null || echo 0) / 1048576 ))
  (( sz >= CL_LOG_WARN_MB )) && { step_begin; warn "previous log" "${sz} MB: the app logs a lot"; }
  summary_box "Start $VNAME" "${C_OK}${G_DOT}${C_0} ${C_B}${CL_TOOL_NAME} ${VNAME}${C_0} ready ${C_DIM}(env $(basename "$ENV_PREFIX"), banner $([ -n "$BANNER" ] && echo ON || echo off))${C_0}"
  out ""
  out "  ${G_ARR}  Local:    $(_link "http://127.0.0.1:$PORT/")"
  local ip first=""
  if [ "$BIND" = 0.0.0.0 ]; then for ip in $(lan_ips); do out "  ${G_ARR}  Network:  $(_link "http://$ip:$PORT/")"; first="${first:-http://$ip:$PORT/}"; done
  elif [ "$BIND" != 127.0.0.1 ]; then out "  ${G_ARR}  Network:  $(_link "http://$BIND:$PORT/")"; first="http://$BIND:$PORT/"; fi
  out "  ${G_ARR}  Logs:     ${log#$TOOL_ROOT/}"
  out "  ${G_ARR}  Stop:     ./$(basename "$SELF") stop --version $VNAME"
  if [ -n "$first" ] && command -v qrencode >/dev/null 2>&1 && [ "$JSON" = 0 ]; then
    out ""; qrencode -t ANSIUTF8 -m 1 "$first" 2>/dev/null | sed 's/^/  /'
  fi
  out ""; out "  ${C_DIM}You can close this terminal: the server keeps running.${C_0}"
  _title "${G_DOT} $CL_TOOL_SHORT $VNAME :$PORT running"
  return 0
}

# ---- Preflight ---------------------------------------------------------------
action_preflight() {
  choose_version "Preflight which version?" || return 1
  choose_env || return 1
  BANNER="${V_BANNER:-}"
  [ "$TTY_OK" = 1 ] && _raw_off
  report_begin preflight "$VNAME"
  print_header
  out "  ${C_B}Preflight${C_0} $VNAME ${C_DIM}with env${C_0} $(basename "$ENV_PREFIX") ${C_DIM}(nothing is started or stopped)${C_0}"
  section "Host" "$HOST"
  step_begin; pass "bash ${BASH_VERSION%%(*}" "$(uname -sm)"
  for c in setsid ss flock timeout; do
    step_begin
    if command -v "$c" >/dev/null 2>&1; then pass "system tool $c"
    else case "$c" in setsid) fail "system tool $c" "missing: servers cannot be detached" "install util-linux" ;;
                     *) warn "system tool $c" "missing: a slower fallback is used" ;; esac; fi
  done
  run_checks preflight
  record_env "$ENV_PREFIX" 2>/dev/null
  [ "$N_FAIL" -gt 0 ] && offer_install "$ENV_PREFIX"
  if [ "$N_FAIL" -eq 0 ]; then summary_box "Preflight $VNAME: ready to start"
  else summary_box "Preflight $VNAME: ${N_FAIL} problem(s)" "fix the FAIL lines above, then run Preflight again"; fi
  if [ "$JSON" = 1 ]; then
    printf '{"action":"preflight","version":"%s","host":"%s","env":"%s","pass":%d,"warn":%d,"fail":%d,"failed":[%s],"report":"%s"}\n' \
      "$(_j "$VNAME")" "$(_j "$HOST")" "$(_j "$ENV_PREFIX")" "$N_PASS" "$N_WARN" "$N_FAIL" "$(_jarr "${FAILS[@]}")" "$(_j "$REPORT")"
  fi
  _title "$CL_TOOL_SHORT preflight: $N_PASS PASS, $N_FAIL FAIL"
  [ "$N_FAIL" -eq 0 ]
}

# ---- Stop --------------------------------------------------------------------
stop_one() { # state file
  local sf="$1"; read_state "$sf"
  local v="${ST_version:-?}" pid="${ST_pid:-}" port="${ST_port:-}" t
  section "Stop" "$v (pid $pid, port $port)"
  state_status "$sf"
  step_begin
  if [ "$STATE" != running ]; then warn "process $pid" "not running (stale record removed)"; rm -f "$sf"; return 0; fi
  pass "process $pid is ours" "user $(id -un), start time matches"
  step_begin
  if [ "$FORCE" = 1 ]; then kill -KILL -- "-$pid" 2>/dev/null; pkill -KILL -s "$pid" 2>/dev/null; pass "SIGKILL sent" "--force"
  else
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; pkill -TERM -s "$pid" 2>/dev/null
    pass "SIGTERM sent" "to process group and session $pid"
    step_begin
    for ((t = 0; t < CL_STOP_TIMEOUT * 4; t++)); do
      kill -0 "$pid" 2>/dev/null || pgrep -s "$pid" >/dev/null 2>&1 || break
      if [ "$TTY_OK" = 1 ]; then printf '\r\033[K  %s%s%s waiting for exit %s%d/%ds%s' "$C_ACC" "${G_SPIN[t % ${#G_SPIN[@]}]}" "$C_0" "$C_DIM" $((t / 4)) "$CL_STOP_TIMEOUT" "$C_0" >&"$TTY"; fi
      _nap 0.25
    done
    [ "$TTY_OK" = 1 ] && printf '\r\033[K' >&"$TTY"
    if kill -0 "$pid" 2>/dev/null || pgrep -s "$pid" >/dev/null 2>&1; then
      kill -KILL -- "-$pid" 2>/dev/null; pkill -KILL -s "$pid" 2>/dev/null; _nap 0.5
      warn "graceful exit" "still alive after ${CL_STOP_TIMEOUT} s: SIGKILL sent"
    else pass "process exited" "gracefully"; fi
  fi
  step_begin
  if kill -0 "$pid" 2>/dev/null; then fail "process $pid" "still running after SIGKILL" "kill -9 $pid by hand, or check for a zombie parent"; return 1; fi
  pass "process gone"
  step_begin
  for ((t = 0; t < 20; t++)); do port_busy "$port" || break; _nap 0.25; done
  if port_busy "$port"; then fail "port $port" "still in use by $(port_owner "$port")" "a child process escaped; see ss -ltnp"
  else pass "port $port free"; fi
  echo "=== $(date '+%F %T') condaLauncher stopped $v" >> "${ST_log:-/dev/null}" 2>/dev/null
  rm -f "$sf"
}
action_stop() {
  local -a files=() items=() f; local i
  for f in "$RUN_DIR"/*.state; do files+=("$f"); done
  local -a mine=() ; local any_stale=0
  for f in "${files[@]}"; do
    state_status "$f"
    case "$STATE" in
      running) mine+=("$f"); local up=$(( $(NOW_EPOCH) - ${ST_started:-$(NOW_EPOCH)} ))
               items+=("${ST_version}"$'\t'"$(printf '%-4s :%-5s up %-7s pid %s' "${ST_role:-}" "$ST_port" "$(_fmt_dur "$up")" "$ST_pid")"$'\t') ;;
      stale) any_stale=1; rm -f "$f" ;;
    esac
  done
  local -a others=()
  for f in "${files[@]}"; do state_status "$f"; [ "$STATE" = other-host ] && others+=("$f"); done
  if [ -n "${OPT_VERSION:-}" ]; then
    local -a pick=(); for f in "${mine[@]}"; do read_state "$f"; [ "$ST_version" = "$OPT_VERSION" ] && pick+=("$f"); done
    mine=("${pick[@]}")
  fi
  if [ "${#mine[@]}" -eq 0 ]; then
    [ "$TTY_OK" = 1 ] && _raw_off
    print_header
    out "  ${C_DIM}${G_ODOT} Nothing of ${CL_TOOL_NAME}${OPT_VERSION:+ $OPT_VERSION} is running on $HOST.${C_0}"
    [ "$any_stale" = 1 ] && out "  ${C_DIM}(stale records from crashed or rebooted runs were cleaned up)${C_0}"
    _report_others "${others[@]}"; return 0
  fi
  local -a chosen=()
  if [ -n "${OPT_VERSION:-}" ] || [ "${OPT_ALL:-0}" = 1 ]; then chosen=("${mine[@]}")
  elif [ "$TTY_OK" != 1 ] && ! [ -t 0 ]; then out "  Not a terminal: use --version V or --all"; return 2
  else
    local -a mi=("${items[@]}")
    for f in "${others[@]}"; do read_state "$f"; mi+=("${ST_version}@${ST_host}"$'\t'"other host: shown only, never stopped from here"$'\t'd); done
    menu_pick "Stop which?" "${#mine[@]} running on $HOST" 0 1 "${mi[@]}" || return 1
    for i in "${MENU_SEL[@]}"; do (( i < ${#mine[@]} )) && chosen+=("${mine[i]}"); done
  fi
  [ "$TTY_OK" = 1 ] && _raw_off
  report_begin stop
  print_header
  take_lock || return 1
  for f in "${chosen[@]}"; do stop_one "$f"; done
  summary_box "Stop: ${#chosen[@]} version(s)"
  _report_others "${others[@]}"
  _title "$CL_TOOL_SHORT: stopped"
  [ "$N_FAIL" -eq 0 ]
}
_report_others() {
  [ "$#" -gt 0 ] || return 0
  local f; out ""; out "  ${C_DIM}On other hosts (not touched):${C_0}"
  for f in "$@"; do read_state "$f"
    local c; c="$(http_code "$ST_host" "$ST_port" "$CL_HEALTH_PATH")"
    out "    ${ST_version}@${ST_host} :${ST_port}  $([[ $c =~ ^[23] ]] && echo "${C_OK}${G_DOT} answers ($c)${C_0}" || echo "${C_DIM}${G_ODOT} no answer${C_0}")"
  done
}

# ---- Diagnostics -------------------------------------------------------------
_j() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; printf '%s' "$s"; }
_jarr() { local f=1 x; for x in "$@"; do [ $f = 1 ] || printf ','; printf '"%s"' "$(_j "$x")"; f=0; done; }
diag_rows() { # -> DROWS (tab separated) and JSON
  discover_versions
  DROWS=(); DJSON=()
  local v i sf code up
  for i in "${!VERS[@]}"; do
    v="${VERS[i]}"; load_version "$v"; sf="$(state_file "$v")"; state_status "$sf"
    local state="down" port="$V_PORT" pid="-" upt="-" health="-" env="-" ban="-" logsz="-"
    if [ "$STATE" = running ]; then
      state="up"; port="$ST_port"; pid="$ST_pid"; up=$(( $(NOW_EPOCH) - ${ST_started:-0} )); upt="$(_fmt_dur "$up")"
      code="$(http_code "$(probe_host "$ST_bind")" "$ST_port" "$CL_HEALTH_PATH")"; health="$code"
      env="$(basename "$ST_env")"; ban="${ST_banner:+ON}"; ban="${ban:-off}"
      logsz="$(du -h "$ST_log" 2>/dev/null | cut -f1)"
    elif [ "$STATE" = stale ]; then state="crashed"
    fi
    [ "${VERS_OK[i]}" = 1 ] || state="broken"
    local icon="$G_ODOT"; case "$state" in up) icon="$G_DOT" ;; crashed|broken) icon="$G_FAIL" ;; esac
    DROWS+=("$v"$'\t'"${V_ROLE:--}"$'\t'"$icon $state"$'\t'"$port"$'\t'"$pid"$'\t'"$upt"$'\t'"$health"$'\t'"$env"$'\t'"$ban"$'\t'"$logsz")
    DJSON+=("{\"version\":\"$(_j "$v")\",\"role\":\"$(_j "${V_ROLE:-}")\",\"state\":\"$state\",\"host\":\"$(_j "$HOST")\",\"port\":${port:-null},\"pid\":$([ "$pid" = - ] && echo null || echo "$pid"),\"uptime_s\":$([ "$state" = up ] && echo "$up" || echo null),\"http\":\"$health\",\"env\":\"$(_j "${ST_env:-}")\",\"banner\":\"$(_j "${ST_banner:-}")\"}")
    for k in "${!ST_@}"; do unset "$k"; done
  done
  local f
  for f in "$RUN_DIR"/*.state; do state_status "$f"; [ "$STATE" = other-host ] || continue
    code="$(http_code "$ST_host" "$ST_port" "$CL_HEALTH_PATH")"
    DROWS+=("${ST_version}@${ST_host}"$'\t'"${ST_role:--}"$'\t'"$G_DOT other host"$'\t'"$ST_port"$'\t'"${ST_pid}"$'\t'"-"$'\t'"$code"$'\t'"$(basename "${ST_env:-}")"$'\t'"-"$'\t'"-")
    DJSON+=("{\"version\":\"$(_j "$ST_version")\",\"state\":\"other-host\",\"host\":\"$(_j "$ST_host")\",\"port\":$ST_port,\"http\":\"$code\"}")
  done
}
diag_table() { # -> lines in DLINES
  local -a H=(VERSION ROLE STATE PORT PID UP HTTP ENV BANNER LOG) w=(); local r i c
  for i in "${!H[@]}"; do w[i]=${#H[i]}; done
  for r in "${DROWS[@]}"; do IFS=$'\t' read -ra c <<<"$r"; for i in "${!c[@]}"; do (( ${#c[i]} > w[i] )) && w[i]=${#c[i]}; done; done
  DLINES=(); local l=""
  _pad() { local p; printf -v p '%*s' $(( $2 - ${#1} )) ''; printf '%s%s' "$1" "$p"; }   # by characters, not bytes
  for i in "${!H[@]}"; do l+="$(_pad "${H[i]}" $((w[i] + 2)))"; done; DLINES+=("  ${C_DIM}${l}${C_0}")
  for r in "${DROWS[@]}"; do
    IFS=$'\t' read -ra c <<<"$r"; l=""
    for i in "${!c[@]}"; do
      local cell; cell="$(_pad "${c[i]}" $((w[i] + 2)))"
      if [ "$i" = 2 ]; then case "${c[i]}" in *" up") cell="${C_OK}${cell}${C_0}" ;; *" down") cell="${C_DIM}${cell}${C_0}" ;;
        *crashed|*broken) cell="${C_ERR}${cell}${C_0}" ;; *) cell="${C_WARN}${cell}${C_0}" ;; esac; fi
      if [ "$i" = 6 ]; then [[ ${c[i]} =~ ^[23] ]] && cell="${C_OK}${cell}${C_0}"; [ "${c[i]}" = 000 ] && cell="${C_ERR}${cell}${C_0}"; fi
      l+="$cell"
    done
    DLINES+=("  $l")
  done
}
action_diagnostics() {
  diag_rows
  if [ "$JSON" = 1 ]; then printf '{"tool":"%s","host":"%s","launcher":"%s","versions":[%s]}\n' "$(_j "$CL_TOOL_NAME")" "$(_j "$HOST")" "$CL_LAUNCHER_VERSION" "$(IFS=,; echo "${DJSON[*]}")"; return 0; fi
  diag_table
  if [ "$TTY_OK" != 1 ] || [ "${OPT_ONCE:-0}" = 1 ]; then print_header; printf '%s\n' "${DLINES[@]}"; _diag_extra; return 0; fi
  _raw_on
  local redraw=1
  while :; do
    if [ "$redraw" = 1 ]; then
      _tty_size; header_lines "$COLS"
      FRAME=("${HDR[@]}" "" "  ${C_B}Diagnostics${C_0}  ${C_DIM}$(printf '%(%H:%M:%S)T' -1)${C_0}" "" "${DLINES[@]}" "" "  ${C_DIM}r refresh ${G_DOTS} l logs ${G_DOTS} q exit${C_0}")
      _frame_flush; redraw=0
    fi
    _read_key || break
    case "$KEY" in
      char:r|char:R) diag_rows; diag_table; redraw=1 ;;
      char:l|char:L) _show_logs; PREV=(); redraw=1 ;;
      char:q|char:Q|esc|enter) break ;;
    esac
  done
  _raw_off; print_header; printf '%s\n' "${DLINES[@]}"; _diag_extra
}
_diag_extra() {
  echo
  local f; f="$(find_frontend && echo "$FE_KIND $FE" || echo none)"
  echo "  ${C_DIM}conda: ${f} ${G_DOTS} records: ${RUN_DIR#$TOOL_ROOT/}/ ${G_DOTS} reports: $(ls "$RUN_DIR"/reports 2>/dev/null | wc -l)${C_0}"
}
_show_logs() {
  local -a items=() logs=(); local f
  for f in "$RUN_DIR"/*@"$HOST".log; do logs+=("$f"); items+=("$(basename "$f" .log)"$'\t'"$(du -h "$f" | cut -f1)"$'\t'); done
  [ "${#logs[@]}" -gt 0 ] || return 0
  menu_pick "Show which log?" "last 40 lines" 0 0 "${items[@]}" || { _raw_on; return 0; }
  _raw_on; _tty_size
  FRAME=("  ${C_B}$(basename "${logs[MENU_IDX]}")${C_0}  ${C_DIM}(any key or click to go back)${C_0}" "")
  while IFS= read -r f; do FRAME+=("  ${f:0:$((COLS - 3))}"); done < <(tail -n $((ROWS - 4)) "${logs[MENU_IDX]}" | _strip)
  _frame_flush
  # mouse motion and button presses are not "a key"; a release (end of a click) is
  while _read_key; do [[ $KEY == mouse:* && $KEY != *m ]] && continue; break; done
}

# ---- Logs --------------------------------------------------------------------
action_logs() {
  local v="${OPT_VERSION:-$(last_used)}"; [ -z "$v" ] && { echo "use --version V"; return 2; }
  local log="$RUN_DIR/$v@$HOST.log"; [ -r "$log" ] || { echo "no log: $log"; return 1; }
  if [ "${OPT_FOLLOW:-0}" = 1 ]; then exec tail -n 100 -f "$log"; else tail -n 100 "$log"; fi
}

# ---- Envs --------------------------------------------------------------------
action_envs() {
  list_envs
  local i
  if [ "$JSON" = 1 ]; then
    local -a j=(); for i in "${!ENV_PREFIXES[@]}"; do j+=("{\"name\":\"$(_j "${ENV_NAMES[i]}")\",\"prefix\":\"$(_j "${ENV_PREFIXES[i]}")\",\"has_interpreter\":$([ -x "$(interp_of "${ENV_PREFIXES[i]}")" ] && echo true || echo false)}"); done
    printf '{"frontend":"%s","envs":[%s]}\n' "$(_j "$FE")" "$(IFS=,; echo "${j[*]}")"; return 0
  fi
  echo "  frontend: ${FE:-none}"
  for i in "${!ENV_PREFIXES[@]}"; do
    printf '  %s %-22s %s\n' "$([ -x "$(interp_of "${ENV_PREFIXES[i]}")" ] && echo "$G_OK" || echo " ")" "${ENV_NAMES[i]}" "${ENV_PREFIXES[i]}"
  done
  echo "  ($G_OK = has $CL_INTERPRETER)"
}

# ---- Help --------------------------------------------------------------------
action_help() {
  print_header
  local me; me="$(basename "$SELF")"
  cat <<EOF
  ${C_B}${CL_TOOL_NAME:-condaLauncher}${C_0}
$( [ -n "$CL_DESCRIPTION" ] && printf '%s\n' "$CL_DESCRIPTION" | fold -s -w 76 | sed 's/^/  /' )

  ${C_B}What this launcher does${C_0}
  One script for every version of this tool. It finds the version folders
  ($CL_VERSION_GLOB) beside it, checks a conda environment, starts the server in the
  background (it keeps running after you close the terminal), stops it again,
  and shows what is running. Every step prints PASS / WARN / FAIL with a fix.

  ${C_B}Menu${C_0}  ${G_UPDN} or j/k move ${G_DOTS} ${G_ENTER} or click select ${G_DOTS} 1-9 jump ${G_DOTS} q back
    Preflight     check env, packages, files and port; changes nothing
    Start server  version ${G_ARR} conda env ${G_ARR} dev banner ${G_ARR} checks ${G_ARR} launch ${G_ARR} health
    Stop server   tick running versions; SIGTERM, ${CL_STOP_TIMEOUT} s, then SIGKILL
    Diagnostics   table of versions; r refresh, l logs

  ${C_B}Without the menu${C_0} (scripts, cron, ssh host cmd)
    $me start [--version V] [--env NAME|PATH] [--banner on|off|TEXT]
              [--port N] [--local] [--timeout S] [--yes]
    $me stop  [--version V | --all] [--force] [--yes]
    $me preflight [--version V] [--env E] [--json] [--install]
    $me status [--json]            same as diagnostics, printed once
    $me logs  [--version V] [-f]
    $me envs  [--json]             conda envs this launcher can see
    $me upgrade NEW_condaLauncher.sh   new engine, same config
  Options for any command: --no-mouse --ascii --no-color --theme night|day

  ${C_B}Files${C_0}
    run/<version>@<host>.state   what is running (pid, port, env, banner)
    run/<version>@<host>.log     server output (last $CL_LOG_KEEP kept)
    run/reports/                 every check report, colour stripped
    <version>/$CL_VERSION_ENV    per-version ROLE, PORT, BANNER, BIND
    <version>/$CL_ENV_RECORD     conda env chosen on each host
  The tool sees CL_BANNER, CL_ROLE, CL_VERSION, CL_PORT, CL_BIND in its environment.

  condaLauncher v$CL_LAUNCHER_VERSION ${G_DOTS} MIT licence
EOF
}

# ---- init / upgrade (writing launchers) --------------------------------------
# Only the FIRST marker pair is the config block (done=1 afterwards): the init
# template further down writes marker lines of its own.
_config_block() { awk '!done && /^# >>> condaLauncher config >>>/{f=1} f{print} f && /^# <<< condaLauncher config <<</{f=0; done=1}' "$1"; }
_engine_with_config() { # engine_file config_file_text_path -> stdout
  awk -v cfg="$2" '
    !done && /^# >>> condaLauncher config >>>/ { while ((getline l < cfg) > 0) print l; skip=1; next }
    skip && /^# <<< condaLauncher config <<</ { skip=0; done=1; next }
    !skip { print }' "$1"
}
CFG_OPEN="# >>> condaLauncher"" config >>>"; CFG_CLOSE="# <<< condaLauncher"" config <<<"
action_upgrade() {
  local new="$1"
  [ -r "$new" ] || { echo "usage: $(basename "$SELF") upgrade /path/to/new/condaLauncher.sh"; return 2; }
  grep -q '^# >>> condaLauncher config >>>' "$new" || { echo "$new is not a condaLauncher script"; return 1; }
  local cfg tmp; cfg="$(mktemp)"; tmp="$(mktemp)"
  _config_block "$SELF" > "$cfg"
  _engine_with_config "$new" "$cfg" > "$tmp"
  bash -n "$tmp" || { echo "the upgraded script does not parse; nothing changed"; rm -f "$cfg" "$tmp"; return 1; }
  # never write into the running file (bash reads scripts while executing them):
  # build beside it and rename, so this process keeps reading the old inode
  cp -p "$SELF" "$SELF.bak" && chmod --reference="$SELF" "$tmp" 2>/dev/null
  mv -f "$tmp" "$SELF.new" && mv -f "$SELF.new" "$SELF" && rm -f "$cfg"
  echo "upgraded $(basename "$SELF"): engine $(grep -m1 '^CL_LAUNCHER_VERSION=' "$new" | cut -d'"' -f2), config kept (backup: $(basename "$SELF").bak)"
}
action_init() {
  local dir="${1:-}"
  [ -n "$dir" ] && [ -d "$dir" ] || { echo "usage: $(basename "$SELF") init /path/to/tool-folder"; return 2; }
  dir="$(cd "$dir" && pwd)"
  print_header
  out "  ${C_B}New launcher for${C_0} $dir"; out ""
  local -a vs=(); local d; for d in "$dir"/v*/; do vs+=("$(basename "$d")"); done
  [ "${#vs[@]}" -gt 0 ] || out "  ${C_WARN}${G_WARN} no v* version folders yet (add them later; the launcher finds them on every run)${C_0}"
  local newest=""; [ "${#vs[@]}" -gt 0 ] && newest="$(printf '%s\n' "${vs[@]}" | sort -V | tail -n1)"
  local kind=custom entry="" nd="$dir/$newest"
  if [ -n "$newest" ]; then
    if [ -e "$nd/app.R" ]; then kind=shiny; entry=app.R
    elif [ -e "$nd/server.R" ]; then kind=shiny; entry=server.R
    else local p; for p in "$nd"/*.py "$nd"/server/*.py "$nd"/src/*.py; do grep -qE 'Flask\(|FastAPI\(|uvicorn|http\.server|streamlit|dash\.Dash' "$p" 2>/dev/null && { kind=python; entry="${p#$nd/}"; break; }; done; fi
  fi
  local port="" ymlname="" lockrel=""
  [ -n "$newest" ] && port="$(sed -n 's/^PORT=//p' "$nd/deploy/version.env" 2>/dev/null | head -n1)"
  local y; for y in "$nd/environment.yml" "$nd/deploy/environment.yml" "$dir/environment.yml"; do [ -r "$y" ] && { ymlname="$(sed -n 's/^name:[[:space:]]*//p' "$y" | head -n1)"; break; }; done
  out "  detected: kind ${C_B}$kind${C_0}${entry:+, entry $entry}, versions ${vs[*]:-none}${ymlname:+, env $ymlname}${port:+, port $port}"; out ""
  local base; base="$(basename "$dir")"; base="${base#[0-9][0-9]_}"
  ask_text "Tool name (shown in menus)" "$base"; local name="$REPLY_TEXT"
  local short; short="$(printf '%s' "$name" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')"; short="${short:0:12}"
  ask_text "Short name (script file, logo)" "$short"; short="$REPLY_TEXT"
  ask_text "Kind: shiny | python | custom" "$kind"; kind="$REPLY_TEXT"
  ask_text "Entry file inside each version folder" "${entry}"; entry="$REPLY_TEXT"
  ask_text "Default port" "${port:-8780}"; port="$REPLY_TEXT"
  ask_text "Conda env name" "${ymlname:-${short}_env}"; local envn="$REPLY_TEXT"
  ask_text "One-line description" "$name web app"; local desc="$REPLY_TEXT"
  local target="$dir/launch-$short.sh"
  if [ -e "$target" ]; then ask_yn "$target exists. Overwrite?" n || return 1; fi
  local cmdline
  case "$kind" in
    shiny) cmdline="CL_CMD=('{INTERP}' -e \"shiny::runApp('.', port={PORT}, host='{BIND}', launch.browser=FALSE)\")" ;;
    python) cmdline="CL_CMD=('{INTERP}' '${entry:-app.py}' --port '{PORT}' --host '{BIND}')   # adjust to your server's flags" ;;
    *) cmdline="CL_CMD=('{INTERP}' '${entry:-app.py}')   # any command; placeholders below" ;;
  esac
  local cfg; cfg="$(mktemp)"
  cat > "$cfg" <<EOF
$CFG_OPEN
# Settings for THIS tool. Everything below the closing marker is the shared engine
# (replace it with: ./launch-$short.sh upgrade /path/to/new/condaLauncher.sh).
CL_TOOL_NAME="$name"
CL_TOOL_SHORT="$short"
CL_DESCRIPTION="$desc"
CL_LOGO_TEXT="$short"           # block-font logo; or paste art into CL_LOGO, or add logo.txt
CL_LOGO=""
CL_KIND="$kind"                 # shiny | python | custom
CL_INTERPRETER="$([ "$kind" = shiny ] && echo Rscript || echo python)"
CL_ENTRY="$entry"               # must exist for a version folder to be launchable
# Command run inside the version folder. Placeholders: {INTERP} {PORT} {BIND}
# {VDIR} {PREFIX} {VERSION} {ENTRY}
$cmdline
CL_HEALTH_PATH="/"
CL_PORT_DEFAULT=${port:-8780}   # used when <version>/deploy/version.env has no PORT
CL_BIND_DEFAULT="0.0.0.0"
CL_ENV_NAME="$envn"
CL_ENV_YML="environment.yml deploy/environment.yml"
CL_ENV_LOCK=""                  # e.g. deploy/${envn}.lock.txt (found automatically if *.lock.txt)
# Requirements, checked in one interpreter call. R: "pkg pkg>=1.2"; Python: "import[:dist][>=ver]"
CL_REQUIRE_R=""
CL_REQUIRE_PY=""
CL_REQUIRE_FILES=""             # extra files that must exist in a version folder
CL_REQUIRE_CMDS=""              # commands needed on PATH inside the env (zip, pandoc ...)
CL_START_TIMEOUT=60
CL_STOP_TIMEOUT=10
CL_BANNER_TEMPLATE="DEVELOPMENT {VERSION} — not for real experiments"
# Optional: export extra variables for the tool (runs in the server's environment).
# Available: CL_BANNER CL_ROLE CL_VERSION CL_PORT CL_BIND CL_VDIR CL_ENV_PREFIX V_<KEY>
# cl_tool_env() { export MYTOOL_BANNER="\$CL_BANNER"; }
$CFG_CLOSE
EOF
  _engine_with_config "$SELF" "$cfg" > "$target" && chmod +x "$target" && _mode "$target"
  rm -f "$cfg"
  bash -n "$target" && out "  ${C_OK}${G_OK}${C_0} wrote ${target}" || { out "  ${C_ERR}${G_FAIL} the written script does not parse${C_0}"; return 1; }
  out "  ${C_DIM}Next: fill CL_REQUIRE_R / CL_REQUIRE_PY in its config block, then run it and choose Preflight.${C_0}"
  out "  ${C_DIM}Add to the tool's .gitignore:  run/   */deploy/launcher.local${C_0}"
}

# ================================================================== main =====
usage_short() { echo "usage: $(basename "$SELF") [start|stop|preflight|status|diagnostics|logs|envs|help|init DIR|upgrade FILE] [options]"; }
main_menu() {
  if [ -z "$CL_TOOL_NAME" ]; then
    local -a items=("Create a launcher for a tool"$'\t'"init: asks a few questions, writes launch-<tool>.sh"$'\t'
                    "Help"$'\t'"how condaLauncher works"$'\t' "Exit"$'\t'$'\t')
    menu_pick "condaLauncher template" "this copy has no tool configured" 0 0 "${items[@]}" || return 0
    case "$MENU_IDX" in
      0) ask_text "Tool folder" "$PWD"; action_init "$REPLY_TEXT" ;;
      1) action_help ;;
    esac
    return
  fi
  local nrun; nrun="$(count_running)"
  local badge=""; [ "$nrun" -gt 0 ] && badge="${G_DOT} $nrun running"
  local -a items=(
    "Preflight checks"$'\t'"conda env, packages, files, port"$'\t'
    "Start server"$'\t'"version ${G_ARR} env ${G_ARR} banner ${G_ARR} launch"$'\t'
    "Stop server"$'\t'"${badge:-nothing running}"$'\t'
    "Diagnostics"$'\t'"what runs where, health, logs"$'\t'
    "Help"$'\t'"what this tool is and how to use it"$'\t'
    "Exit"$'\t'$'\t'
  )
  menu_pick "Main menu" "" 0 0 "${items[@]}"
  case $? in 1) return 0 ;; 2) echo "No interactive terminal. $(usage_short)"; return 2 ;; esac
  case "$MENU_IDX" in
    0) action_preflight ;; 1) action_start ;; 2) action_stop ;; 3) action_diagnostics ;;
    4) _raw_off; action_help ;; *) return 0 ;;
  esac
}

main() {
  local cmd="" ; local -a rest=()
  OPT_VERSION=""; OPT_INSTALL=0; OPT_ENV=""; OPT_BANNER=""; OPT_PORT=""; OPT_BIND=""; OPT_ALL=0; OPT_FOLLOW=0; OPT_ONCE=0; OPT_TIMEOUT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version|-V) [ -n "${2:-}" ] && [[ $2 != -* ]] && { OPT_VERSION="$2"; shift 2; continue; }; echo "condaLauncher $CL_LAUNCHER_VERSION"; return 0 ;;
      --env) OPT_ENV="$2"; shift 2 ;;
      --banner) OPT_BANNER="$2"; shift 2 ;;
      --port) OPT_PORT="$2"; shift 2 ;;
      --bind) OPT_BIND="$2"; shift 2 ;;
      --local) OPT_BIND=127.0.0.1; shift ;;
      --timeout) OPT_TIMEOUT="$2"; shift 2 ;;
      --all) OPT_ALL=1; shift ;;
      --force) FORCE=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --install) OPT_INSTALL=1; shift ;;
      --json) JSON=1; shift ;;
      -f|--follow) OPT_FOLLOW=1; shift ;;
      --no-mouse) CL_MOUSE=0; shift ;;
      --ascii) CL_ASCII=1; shift ;;
      --no-color) NO_COLOR=1; shift ;;
      --theme) CL_THEME="$2"; shift 2 ;;
      -h|--help) cmd=help; shift ;;
      -*) echo "unknown option: $1"; usage_short; return 2 ;;
      *) if [ -z "$cmd" ]; then cmd="$1"; else rest+=("$1"); fi; shift ;;
    esac
  done
  _term_init; _glyphs; _theme_init; load_logo
  [ "$JSON" = 1 ] && { COLOR=0; C_ACC=""; C_ACC2=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_LINK=""; C_B=""; C_0=""; C_REV=""; }
  if [ -n "$cmd" ] && [ -z "$CL_TOOL_NAME" ] && [[ $cmd != @(help|init|upgrade|envs) ]]; then
    echo "This is the condaLauncher template. Create a launcher first: $(basename "$SELF") init /path/to/tool"; return 2
  fi
  case "$cmd" in
    "") main_menu ;;
    start) action_start ;;
    stop) action_stop ;;
    preflight|check) action_preflight ;;
    status) OPT_ONCE=1; action_diagnostics ;;
    diagnostics|diag) action_diagnostics ;;
    logs|log) action_logs ;;
    envs) action_envs ;;
    help) action_help ;;
    init) action_init "${rest[0]:-}" ;;
    upgrade) action_upgrade "${rest[0]:-}" ;;
    *) usage_short; return 2 ;;
  esac
}
main "$@"
