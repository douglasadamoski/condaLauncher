#!/usr/bin/env bash
# End-to-end tests for condaLauncher, run against a scratch copy of examples/demo-tool.
#   bash tests/run_all.sh                 uses the first conda env that has python
#   CL_TEST_ENV=/path/to/env bash tests/run_all.sh
# Needs: a conda env with python 3, free ports 18761-18763 and 18791-18794 (and 18771-18780 for the pool tests, which
# also need caddy on PATH or CL_TEST_CADDY=/path/to/caddy; without it they are skipped). Leaves nothing running.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; V="$(dirname "$HERE")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cl-test.XXXXXX")"
cp -r "$V/examples/demo-tool/." "$WORK/"; rm -rf "$WORK/run"
L="$WORK/launch-demo.sh"
export CL_NO_TTY=1 NO_COLOR=1 CL_SITE_FILE=/dev/null
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -n 15 | sed 's/^/        | /'; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
http() { local r; r="$(timeout 4 bash -c 'exec 3<>/dev/tcp/127.0.0.1/$1 || exit 1; printf "GET / HTTP/1.0\r\n\r\n" >&3; cat <&3' _ "$1" 2>/dev/null)"; printf '%s' "$r"; }
cleanup() { "$L" stop --all --yes --force </dev/null >/dev/null 2>&1; [ -n "${BLOCK_PID:-}" ] && kill "$BLOCK_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

ENVP="${CL_TEST_ENV:-}"
if [ -z "$ENVP" ]; then
  ENVP="$("$L" envs --json </dev/null | grep -o '"prefix":"[^"]*","has_interpreter":true' | head -n1 | sed 's/"prefix":"\([^"]*\)".*/\1/')"
fi
[ -x "$ENVP/bin/python" ] || { echo "no conda env with python found; set CL_TEST_ENV"; exit 2; }
echo "condaLauncher tests  (env: $(basename "$ENVP"), scratch: $WORK)"

echo "-- syntax and plain-shell start"
check "template parses"            bash -n "$V/condaLauncher.sh"
check "demo launcher parses"       bash -n "$L"
out="$(env -i HOME="$HOME" TERM=dumb PATH=/usr/bin:/bin bash "$L" status </dev/null 2>&1)"
[[ $out == *v0.1*v0.2* || $out == *v0.2*v0.1* ]] && ok "runs with no conda on PATH (env -i)" || bad "runs with no conda on PATH (env -i)" "$out"
out="$(timeout 5 "$L" </dev/null 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "menu without a terminal exits (rc 2), no hang" || bad "menu without a terminal exits (rc $rc)" "$out"
out="$("$L" --help </dev/null)"; [[ $out == *"Without the menu"* ]] && ok "help prints" || bad "help prints" "$out"

echo "-- preflight"
out="$("$L" preflight --version v0.2 --env "$ENVP" --json </dev/null)"
[[ $out == *'"fail":0'* ]] && ok "preflight v0.2 passes (json)" || bad "preflight v0.2 passes" "$out"
out="$("$L" preflight --version v0.3-broken --env "$ENVP" </dev/null)"; rc=$?
[ "$rc" = 1 ] && [[ $out == *"no entry point"* ]] && ok "broken version reported by preflight" || bad "broken version reported (rc $rc)" "$out"
ls "$WORK"/run/reports/*preflight* >/dev/null 2>&1 && ok "report files written" || bad "report files written"
grep -q $'\033' "$WORK"/run/reports/*.log && bad "reports contain escape codes" || ok "reports are plain text"

echo "-- start two versions side by side"
t0=$SECONDS
out="$("$L" start --version v0.2 --env "$ENVP" --yes </dev/null 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "start v0.2 (dev)" || bad "start v0.2 (rc $rc)" "$out"
out="$("$L" start --version v0.1 --env "$ENVP" --yes </dev/null 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "start v0.1 (prod)" || bad "start v0.1 (rc $rc)" "$out"
(( SECONDS - t0 < 30 )) && ok "launcher returned while servers keep running" || bad "launcher took $((SECONDS - t0)) s"
[[ $(http 18762) == *"DEVELOPMENT v0.2"* ]] && ok "v0.2 serves the dev banner (ROLE=dev default)" || bad "v0.2 banner" "$(http 18762)"
r="$(http 18761)"; [[ $r == *"Demo tool v0.1"* && $r != *DEVELOPMENT* ]] && ok "v0.1 serves without banner (ROLE=prod)" || bad "v0.1 no banner" "$r"
out="$("$L" status --json </dev/null)"
[ "$(grep -o '"state":"up"' <<<"$out" | wc -l)" = 2 ] && ok "status --json: 2 up" || bad "status --json: 2 up" "$out"
grep -q "^$(hostname -s | cut -d. -f1).prefix=$ENVP" "$WORK/v0.2/deploy/launcher.local" && ok "env recorded per host" || bad "env recorded per host"
[ "$(cat "$WORK"/run/last@*)" = v0.1 ] && ok "last used version recorded" || bad "last used version recorded"

echo "-- locks are not leaked to servers"
t0=$SECONDS; "$L" stop --version nothing-here --yes </dev/null >/dev/null 2>&1
out="$("$L" start --version v0.1 --env "$ENVP" --yes </dev/null 2>&1)"; rc=$?
(( SECONDS - t0 < 10 )) && ok "second run does not wait on a lock" || bad "second run waited $((SECONDS - t0)) s"
[ "$rc" = 1 ] && [[ $out == *"already running"* ]] && ok "start refuses a running version" || bad "start refuses a running version (rc $rc)" "$out"

echo "-- stop one, the other stays"
out="$("$L" stop --version v0.2 --yes </dev/null 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "stop v0.2" || bad "stop v0.2 (rc $rc)" "$out"
[ -z "$(http 18762)" ] && ok "port 18762 freed" || bad "port 18762 freed"
[[ $(http 18761) == *"v0.1"* ]] && ok "v0.1 still up" || bad "v0.1 still up"

echo "-- banner text"
"$L" stop --version v0.1 --yes </dev/null >/dev/null 2>&1
out="$("$L" start --version v0.1 --env "$ENVP" --banner on --yes </dev/null 2>&1)"
[[ $(http 18761) == *"DEVELOPMENT v0.1 — not for real experiments"* ]] && ok "default banner template expands {VERSION}" || bad "default banner template" "$(http 18761 | tail -c 300)"
"$L" stop --version v0.1 --yes </dev/null >/dev/null 2>&1
"$L" start --version v0.1 --env "$ENVP" --banner off --yes </dev/null >/dev/null 2>&1

echo "-- busy port falls back"
python3 -m http.server 18762 --bind 127.0.0.1 >/dev/null 2>&1 & BLOCK_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(http 18762)" ] && break; sleep 0.2; done
out="$("$L" start --version v0.2 --env "$ENVP" --banner off --yes </dev/null 2>&1)"; rc=$?
[ "$rc" = 0 ] && [[ $out == *"using 18763"* ]] && ok "busy port 18762 -> 18763 with WARN" || bad "busy port fallback (rc $rc)" "$out"
r="$(http 18763)"; [[ $r == *"v0.2"* && $r != *DEVELOPMENT* ]] && ok "--banner off honoured" || bad "--banner off honoured" "$r"
kill "$BLOCK_PID" 2>/dev/null; BLOCK_PID=""

echo "-- crash and stale records"
pid="$(sed -n 's/^pid=//p' "$WORK"/run/v0.2@*.state)"; kill -9 -- "-$pid" 2>/dev/null; sleep 0.5
out="$("$L" status </dev/null)"; [[ $out == *crashed* ]] && ok "killed server shows as crashed" || bad "crashed state" "$out"
out="$("$L" stop --version v0.2 --yes </dev/null 2>&1)"
ls "$WORK"/run/v0.2@*.state >/dev/null 2>&1 && bad "stale record removed" || ok "stale record removed"

echo "-- stop all"
out="$("$L" stop --all --yes </dev/null 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$(http 18761)" ] && ok "stop --all" || bad "stop --all (rc $rc)" "$out"
[ "$("$L" status --json </dev/null | grep -c '"state":"up"')" = 0 ] && ok "nothing left running" || bad "nothing left running"

echo "-- a missing command is offered for install"
sed 's/^CL_REQUIRE_CMDS=""/CL_REQUIRE_CMDS="nosuchcmd=nosuchpkg"/' "$L" > "$WORK/launch-cmd.sh"; chmod +x "$WORK/launch-cmd.sh"
out="$("$WORK/launch-cmd.sh" preflight --version v0.1 --env "$ENVP" </dev/null 2>&1)"; rc=$?
[ "$rc" = 1 ] && [[ $out == *"command nosuchcmd"* && $out == *"install -p"*"nosuchpkg"* ]] && ok "missing command fails with an install line naming the conda package" || bad "missing command (rc $rc)" "$out"
[[ $out == *"re-run with --install"* ]] && ok "and points to --install (never installs on its own)" || bad "install offer text" "$out"
rm -f "$WORK/launch-cmd.sh"

echo "-- workers need the tool's declaration"
sed 's/^CL_WORKERS_MAX=4$/CL_WORKERS_MAX=0/' "$L" > "$WORK/launch-nowork.sh"; chmod +x "$WORK/launch-nowork.sh"
out="$("$WORK/launch-nowork.sh" start --version v0.1 --env "$ENVP" --workers 2 --yes </dev/null 2>&1)"; rc=$?
[ "$rc" = 1 ] && [[ $out == *"has not declared support for workers"* ]] && [ -z "$(http 18761)" ] && ok "a tool without CL_WORKERS_MAX refuses --workers 2 (and starts nothing)" || bad "undeclared workers (rc $rc)" "$out"
out="$("$WORK/launch-nowork.sh" start --version v0.1 --env "$ENVP" --workers 1 --yes </dev/null 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the same tool still starts with --workers 1" || bad "--workers 1 on an undeclared tool (rc $rc)" "$out"
"$L" stop --version v0.1 --yes </dev/null >/dev/null 2>&1; rm -f "$WORK/launch-nowork.sh"
out="$("$L" start --version v0.1 --env "$ENVP" --workers 9 --yes </dev/null 2>&1)"; rc=$?
[ "$rc" = 1 ] && [[ $out == *"allows at most 4"* ]] && ok "--workers above CL_WORKERS_MAX is refused" || bad "--workers 9 (rc $rc)" "$out"

echo "-- pool: start --workers N"
CADDY="${CL_TEST_CADDY:-$(command -v caddy || true)}"
if [ -z "$CADDY" ] || [ ! -x "$CADDY" ]; then echo "  SKIP  no caddy on PATH (set CL_TEST_CADDY=/path/to/caddy to run these)"
else
  export PATH="$(dirname "$CADDY"):$PATH"
  out="$("$L" start --version v0.1 --env "$ENVP" --workers abc --yes </dev/null 2>&1)"; rc=$?
  [ "$rc" = 1 ] && [[ $out == *"not a number"* ]] && ok "--workers abc is refused" || bad "--workers abc (rc $rc)" "$out"
  out="$("$L" start --version v0.1 --env "$ENVP" --workers 1 --yes </dev/null 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [[ $out == *"pool of 1"* ]] && [ -z "$(ls "$WORK"/run/v0.1~w* 2>/dev/null)" ] && ok "--workers 1 warns and runs one plain process" || bad "--workers 1 (rc $rc)" "$out"
  "$L" stop --version v0.1 --yes </dev/null >/dev/null 2>&1
  sed 's/^CL_WORKERS_DEFAULT=0$/CL_WORKERS_DEFAULT=2/' "$L" > "$WORK/launch-dflt.sh"; chmod +x "$WORK/launch-dflt.sh"
  grep -q '^CL_WORKERS_DEFAULT=2$' "$WORK/launch-dflt.sh" || sed -i 's/^CL_WORKERS_MAX=4$/CL_WORKERS_MAX=4\nCL_WORKERS_DEFAULT=2/' "$WORK/launch-dflt.sh"
  out="$("$WORK/launch-dflt.sh" start --version v0.1 --env "$ENVP" --yes </dev/null 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [[ $out == *"all 2 workers answer"* ]] && ok "CL_WORKERS_DEFAULT=2 starts a pool with no flag" || bad "default workers (rc $rc)" "$out"
  "$L" stop --version v0.1 --yes </dev/null >/dev/null 2>&1; rm -f "$WORK/launch-dflt.sh"
  out="$("$L" start --version v0.1 --env "$ENVP" --workers 3 --yes </dev/null 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [[ $out == *"all 3 workers answer"* ]] && ok "start --workers 3" || bad "start --workers 3 (rc $rc)" "$out"
  [[ $(http 18761) == *"Demo tool v0.1"* ]] && ok "the public port answers through the proxy" || bad "public port through the proxy" "$(http 18761)"
  [ "$(ls "$WORK"/run/v0.1~w*@*.state 2>/dev/null | wc -l)" = 3 ] && ok "three worker records" || bad "three worker records"
  out="$("$L" status </dev/null)"; [ "$(grep -c ' worker ' <<<"$out")" = 3 ] && ok "status lists the three workers under the version" || bad "status lists workers" "$out"
  if command -v curl >/dev/null 2>&1; then
    cks=""; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do rm -f "$WORK/jar$i"; curl -s -o /dev/null -c "$WORK/jar$i" http://127.0.0.1:18761/; cks+="$(awk '$6=="clw"{print $7}' "$WORK/jar$i")"$'\n'; done
    [ "$(sort -u <<<"$cks" | grep -c .)" -ge 2 ] && ok "fresh browsers are spread over several workers" || bad "spread over workers" "$cks"
    c1="$(awk '$6=="clw"{print $7}' "$WORK/jar1")"; curl -s -o /dev/null -b "$WORK/jar1" -c "$WORK/jar1" http://127.0.0.1:18761/
    [ "$(awk '$6=="clw"{print $7}' "$WORK/jar1")" = "$c1" ] && ok "a browser with the cookie stays on its worker" || bad "cookie stickiness"
    # freeze worker 1 (stands in for a worker busy with a long export), hold one request open on it as the export would
    wpid="$(sed -n 's/^pid=//p' "$WORK"/run/v0.1~w1@*.state)"
    kill -STOP -- "-$wpid" 2>/dev/null || kill -STOP "$wpid"
    held=""; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -b "$WORK/jar$i" http://127.0.0.1:18761/)" = 000 ] && { held="$i"; break; }; done
    if [ -z "$held" ]; then bad "no browser was pinned to the frozen worker"
    else
      curl -s -o /dev/null --max-time 40 -b "$WORK/jar$held" http://127.0.0.1:18761/ & HOLD_PID=$!
      sleep 1; n_ok=0
      for i in 1 2 3 4 5 6 7 8; do rm -f "$WORK/jarn"; code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -c "$WORK/jarn" http://127.0.0.1:18761/)"; [ "$code" = 200 ] && n_ok=$((n_ok + 1)); done
      [ "$n_ok" = 8 ] && ok "with a worker stuck on a long request, 8 new browsers are all served by the others" || bad "frozen worker: $n_ok/8 served"
      kill -CONT -- "-$wpid" 2>/dev/null || kill -CONT "$wpid"; wait "$HOLD_PID" 2>/dev/null
    fi
  else echo "  SKIP  no curl: stickiness and frozen-worker checks"; fi
  out="$("$L" stop --version v0.1 --yes </dev/null 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ -z "$(http 18761)" ] && [ -z "$(ls "$WORK"/run/*.state 2>/dev/null)" ] && ok "stop takes the proxy and all workers, no records left" || bad "pool stop (rc $rc)" "$out"
  [ -z "$(ss -ltnH 'sport >= :18771 and sport <= :18780' 2>/dev/null)" ] && ok "worker ports freed" || bad "worker ports freed"
fi

echo "-- other hosts are reported, never touched"
printf 'pid=1\nstarttime=1\nhost=other-host\nversion=v0.1\nport=18761\nbind=127.0.0.1\nenv=/x\nbanner=\nrole=prod\nstarted=1\nlog=/dev/null\n' > "$WORK/run/v0.1@other-host.state"
out="$("$L" stop --all --yes </dev/null 2>&1)"
[ -f "$WORK/run/v0.1@other-host.state" ] && [[ $out == *"other hosts"* ]] && ok "other-host record kept and reported" || bad "other-host" "$out"
rm -f "$WORK/run/v0.1@other-host.state"

echo "-- logo colour markup"
mk="$WORK/logo.txt"; printf 'AB {r}CD{/} EF\n{g}GH{/}\n' > "$mk"
out="$("$L" status </dev/null)"
[[ $out == *"AB CD EF"* && $out != *"{r}"* ]] && ok "logo markup removed without colour" || bad "logo markup removed" "$(head -3 <<<"$out")"
out="$(env -u NO_COLOR FORCE_COLOR=1 CL_COLOR_DEPTH=256 "$L" status </dev/null)"
[[ $out == *$'\033[38;5;211mCD'* ]] && ok "logo markup coloured ({r} = theme red)" || bad "logo markup coloured" "$(head -3 <<<"$out" | cat -v)"
rm -f "$mk"

echo "-- port follows the banner (CL_PORT_PROD / CL_PORT_DEV, 0.1.5)"
"$L" stop --all --yes --force </dev/null >/dev/null 2>&1
sed 's/^\(CL_PORT_DEFAULT=.*\)$/\1\nCL_PORT_PROD=18791\nCL_PORT_DEV=18792/' "$L" > "$WORK/launch-role.sh"; chmod +x "$WORK/launch-role.sh"
R="$WORK/launch-role.sh"
out="$("$R" start --version v0.1 --env "$ENVP" --banner off --yes </dev/null 2>&1)"; rc=$?
r="$(http 18791)"; [ "$rc" = 0 ] && [[ $r == *"Demo tool v0.1"* && $r != *DEVELOPMENT* ]] && ok "banner off -> prod port 18791" || bad "banner off -> prod port (rc $rc)" "$out"
out="$("$R" start --version v0.2 --env "$ENVP" --banner on --yes </dev/null 2>&1)"; rc=$?
r="$(http 18792)"; [ "$rc" = 0 ] && [[ $r == *"DEVELOPMENT v0.2"* ]] && ok "banner on -> dev port 18792 (version.env PORT=18762 ignored)" || bad "banner on -> dev port (rc $rc)" "$out"
[ -z "$(http 18762)" ] && ok "version.env PORT not used when role ports are set" || bad "version.env PORT used"
"$R" stop --all --yes --force </dev/null >/dev/null 2>&1
out="$("$R" start --version v0.1 --env "$ENVP" --yes </dev/null 2>&1)"; rc=$?
[ -n "$(http 18791)" ] && ok "--yes on a ROLE=prod version: no banner -> prod port" || bad "--yes prod default (rc $rc)" "$out"
out="$("$R" start --version v0.2 --env "$ENVP" --yes </dev/null 2>&1)"; rc=$?
r="$(http 18792)"; [[ $r == *DEVELOPMENT* ]] && ok "--yes on a ROLE=dev version: banner -> dev port" || bad "--yes dev default (rc $rc)" "$out"
"$R" stop --all --yes --force </dev/null >/dev/null 2>&1
out="$("$R" preflight --version v0.2 --env "$ENVP" </dev/null 2>&1)"
[[ $out == *"port by role"* && $out == *"PORT=18762"*"ignored"* ]] && ok "preflight shows the role port and warns about the ignored PORT=" || bad "preflight role port" "$out"
python3 -m http.server 18791 --bind 127.0.0.1 >/dev/null 2>&1 & BLOCK_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(http 18791)" ] && break; sleep 0.2; done
out="$("$R" start --version v0.1 --env "$ENVP" --banner off --yes </dev/null 2>&1)"; rc=$?
[ "$rc" = 0 ] && [[ $out == *"using 18793"* ]] && [ -z "$(http 18792)" ] && ok "busy prod port never falls back onto the dev port (18791 -> 18793)" || bad "role-port fallback (rc $rc)" "$out"
kill "$BLOCK_PID" 2>/dev/null; BLOCK_PID=""
"$R" stop --all --yes --force </dev/null >/dev/null 2>&1
out="$("$R" start --version v0.1 --env "$ENVP" --banner off --port 18794 --yes </dev/null 2>&1)"; rc=$?
[ -n "$(http 18794)" ] && [ -z "$(http 18791)" ] && ok "--port still overrides the role port" || bad "--port override (rc $rc)" "$out"
"$R" stop --all --yes --force </dev/null >/dev/null 2>&1; rm -f "$R"

echo "-- init and upgrade"
mkdir -p "$WORK/newtool/v1.0" && cp "$WORK/v0.1/server.py" "$WORK/newtool/v1.0/app.py"
sed -i 's/ThreadingHTTPServer((a.host/ThreadingHTTPServer((a.host/' "$WORK/newtool/v1.0/app.py"
out="$("$V/condaLauncher.sh" init "$WORK/newtool" </dev/null 2>&1)"
[ -x "$WORK/newtool/launch-newtool.sh" ] && bash -n "$WORK/newtool/launch-newtool.sh" && ok "init writes a working launcher" || bad "init" "$out"
grep -q 'CL_KIND="python"' "$WORK/newtool/launch-newtool.sh" && ok "init detects a python server" || bad "init detects python"
before="$(awk '/^# >>> condaLauncher config/,/^# <<< condaLauncher config/' "$L" | md5sum)"
"$L" upgrade "$V/condaLauncher.sh" >/dev/null 2>&1; rc=$?
after="$(awk '/^# >>> condaLauncher config/,/^# <<< condaLauncher config/' "$L" | md5sum)"
[ "$rc" = 0 ] && [ "$before" = "$after" ] && bash -n "$L" && ok "upgrade keeps the config block" || bad "upgrade (rc $rc)"
eng() { sed '1,/^# <<< condaLauncher config <<</d' "$1"; }
[ "$(eng "$V/condaLauncher.sh" | md5sum)" = "$(eng "$L" | md5sum)" ] && ok "upgraded engine identical to the template" || bad "upgraded engine differs from the template"
[ "$(grep -c '^# >>> condaLauncher config >>>' "$L")" = 1 ] && ok "exactly one config block after upgrade" || bad "config block count"
mkdir -p "$WORK/third/v2" && cp "$WORK/v0.1/server.py" "$WORK/third/v2/app.py"
out="$("$L" init "$WORK/third" </dev/null 2>&1)"
[ -x "$WORK/third/launch-third.sh" ] && bash -n "$WORK/third/launch-third.sh" && [ "$(grep -c '^# >>> condaLauncher config >>>' "$WORK/third/launch-third.sh")" = 1 ] \
  && ok "init from a tool's launcher (not the template) works" || bad "init from a tool's launcher" "$out"

echo
echo "condaLauncher tests: $PASS/$((PASS + FAIL)) PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
