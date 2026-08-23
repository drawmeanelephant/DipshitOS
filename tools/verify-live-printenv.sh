#!/usr/bin/env bash
#
# verify-live-printenv.sh -- M22 D7 class-B gate (issue #330, claim 9815):
# the monitor's printenv dumps the shell environment table.
#
# Chain: a one-line script sets an env var through the shell's `export`
# builtin (`sh ENVSET.TXT`), then `printenv` prints KEY=VALUE lines
# including it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/m22-printenv-live.txt"
exec > >(tee "$GATE_LOG") 2>&1

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-printenv-report.txt"
SCRIPT="artifacts/live-printenv-script.txt"

echo "=== verify-live-printenv: M22 D7 (issue #330) — shell env dump, $BOOTS boot(s) ==="
zig version | head -1
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

printf 'write ENVSET.TXT export D7VAR=m22-lane-d\nsh ENVSET.TXT\nprintenv\necho rx-printenv-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-printenv-run-$tag.txt"
    local serial_copy="artifacts/live-printenv-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-after "tasks user-el0 exited status=7" \
        --script-expect "rx-printenv-ok" --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 written=0 dumped=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "write: ok" artifacts/vm-serial.log || true)" = 1 ] && written=1
        [ "$(grep -aFxc -- "D7VAR=m22-lane-d" artifacts/vm-serial.log || true)" = 1 ] && dumped=1
        [ "$(grep -aFxc -- "rx-printenv-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner written=$written dumped=$dumped echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$written" = 1 ] && [ "$dumped" = 1 ] && \
        [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live printenv gate (M22 D7, issue #330, claim 9815)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-printenv: PASS — env var set via shell export surfaced in printenv's KEY=VALUE dump ($pass/$BOOTS)."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-printenv: FAILED — $pass/$BOOTS."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
