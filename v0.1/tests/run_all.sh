#!/usr/bin/env bash
# End-to-end tests for condaLauncher, run against a scratch copy of examples/demo-tool.
#   bash tests/run_all.sh                 uses the first conda env that has python
#   CL_TEST_ENV=/path/to/env bash tests/run_all.sh
# Needs: a conda env with python 3, free ports 18761-18763. Leaves nothing running.
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

echo "-- other hosts are reported, never touched"
printf 'pid=1\nstarttime=1\nhost=other-host\nversion=v0.1\nport=18761\nbind=127.0.0.1\nenv=/x\nbanner=\nrole=prod\nstarted=1\nlog=/dev/null\n' > "$WORK/run/v0.1@other-host.state"
out="$("$L" stop --all --yes </dev/null 2>&1)"
[ -f "$WORK/run/v0.1@other-host.state" ] && [[ $out == *"other hosts"* ]] && ok "other-host record kept and reported" || bad "other-host" "$out"
rm -f "$WORK/run/v0.1@other-host.state"

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
