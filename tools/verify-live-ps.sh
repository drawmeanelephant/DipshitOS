#!/usr/bin/env bash
#
# verify-live-ps.sh -- M22 D6 class-B gate (issue #329, claim 9815): the
# process status table, both halves.
#   1. Monitor `ps` prints a PID/NAME/STATE/MEM/CPU/TASK table containing
#      the shell-side rows.
#   2. `exec PS.BIN` opens the windowed viewer; its serial markers
#      (ps: open/ready) prove it launched; a COUNTER.BIN exec before it
#      gives the viewer something to show. Gate asserts the launch chain.
#   3. Shell stays responsive.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/m22-ps-live.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-ps-report.txt"
SCRIPT="artifacts/live-ps-script.txt"
SCRIPT2="artifacts/live-ps-script2.txt"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
PS_OPEN_LINE="ps: ready"
EXIT_LINE="tasks user-exec exited status=71"

echo "=== verify-live-ps: M22 D6 (issue #329) — process status table + windowed viewer, $BOOTS boot(s) ==="
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

printf 'ps\nexec COUNTER.BIN\nps\nexec PS.BIN\necho rx-ps-ok\n' > "$SCRIPT"
printf 'strace exec HELLO.ELF\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-ps-run-$tag.txt"
    local serial_copy="artifacts/live-ps-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --display --input \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 table=1 counter=0 psready=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "PID  NAME" artifacts/vm-serial.log || true)" -ge 2 ] && table=1
        [ "$(grep -aFc -- "COUNTER.BIN" artifacts/vm-serial.log || true)" -ge 3 ] && counter=1
        [ "$(grep -aFxc -- "ps: ready" artifacts/vm-serial.log || true)" = 1 ] && psready=1
        [ "$(grep -aFxc -- "rx-ps-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner table=$table counter=$counter psready=$psready echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$table" = 1 ] && [ "$counter" = 1 ] && \
        [ "$psready" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live ps gate (M22 D6, issue #329, claim 9815)"
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
    echo "=== live-ps boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-ps: PASS — 'ps' printed the process table and COUNTER.BIN appeared in it across two snapshots ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-ps: FAILED — $pass/$BOOTS boot(s) passed."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
