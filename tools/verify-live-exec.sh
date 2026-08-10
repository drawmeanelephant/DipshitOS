#!/usr/bin/env bash
#
# verify-live-exec.sh -- claim 6783 class-B gate: a real user program loaded
# from the ESP and entered at EL0 on real VZ hardware (march-m3 card 6).
#
# The chain, all asserted in vm-serial.log:
#   1. USER.BIN (a DSK1 flat image built from user/src/main.zig) is on the
#      ESP — the image builder embeds it, `ls` lists it.
#   2. `exec USER.BIN` reads it through the claim-6420 FAT path, validates
#      the DSK1 header, rebuilds the EL0 user root around the loaded page
#      (claim 5804), and spawns an EL0t task — the reply line
#      "exec: loaded USER.BIN size=..." proves the load.
#   3. The loaded program executes at EL0: its sys_write marker lines
#      ("user: hello from the ESP", "user: exec ok") land in the serial log
#      directly, two sequenced sys_ping calls prove SVC round-trips from a
#      LOADED image, and sys_exit (status 42) closes the claim-6729
#      lifecycle ("tasks user-exec exited status=42" + reap).
#   4. The shell stays responsive (echo reply).
#
# The script is forwarded only AFTER the static claim-8215 payload has
# exited ("tasks user-el0 exited status=7"): exec requires the user root
# free (one user program at a time).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/m3-exec-live.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-exec-report.txt"
SCRIPT="artifacts/live-exec-script.txt"
# The static claim-8215 payload's exit line: the runner forwards the script
# only after it appears, so the user root is free when `exec` runs.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The exec'd program's exit line (asserted) and its reap line (asserted
# AND the script-expect — the reap prints a quantum after the exit, so it
# is the last line in the log).
EXEC_EXIT_LINE="tasks user-exec exited status=42"
EXEC_REAP_LINE="tasks user-exec reaped"

echo "=== verify-live-exec: claim 6783 — load + exec a user program from the ESP at EL0, $BOOTS boot(s) ==="
zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

printf 'ls\nexec USER.BIN\necho rx-exec-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-exec-run-$tag.txt"
    local serial_copy="artifacts/live-exec-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script-expect "$EXEC_REAP_LINE" --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 listed=0 loaded=0 hello=0 ok=0 exited=0 reaped=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "USER.BIN" artifacts/vm-serial.log || true)" -ge 2 ] && listed=1
        [ "$(grep -aFc -- "exec: loaded USER.BIN size=" artifacts/vm-serial.log || true)" = 1 ] && loaded=1
        [ "$(grep -aFc -- "user: hello from the ESP" artifacts/vm-serial.log || true)" = 1 ] && hello=1
        [ "$(grep -aFc -- "user: exec ok" artifacts/vm-serial.log || true)" = 1 ] && ok=1
        [ "$(grep -aFc -- "$EXEC_EXIT_LINE" artifacts/vm-serial.log || true)" = 1 ] && exited=1
        [ "$(grep -aFxc -- "$EXEC_REAP_LINE" artifacts/vm-serial.log || true)" = 1 ] && reaped=1
        [ "$(grep -aFxc -- "rx-exec-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed loaded=$loaded hello=$hello ok=$ok exited=$exited reaped=$reaped echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$loaded" = 1 ] && \
        [ "$hello" = 1 ] && [ "$ok" = 1 ] && [ "$exited" = 1 ] && [ "$reaped" = 1 ] && \
        [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live exec gate (claim 6783) — load + exec a user program from the ESP at EL0"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-exec boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-exec: PASS — USER.BIN loaded from the ESP through the FAT path and entered at EL0; its sys_write markers + exit/reap observed ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-exec: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
