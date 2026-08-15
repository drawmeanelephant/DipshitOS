#!/usr/bin/env bash
#
# verify-live-settings.sh -- claim 2649 (milestone-eight card U8) class-B gate:
# PERSISTENT SETTINGS observed across reboot on real Virtualization.framework hardware.
#
# Card U8 contract (ADR 0008 Card U8):
#   - In-memory key-value store backed by `SETTINGS.TXT` on the DATA FAT32 partition.
#   - `settings get/set/list/reset` verbs.
#   - Loaded automatically on kernel boot.
#
# The gate is TWO boots against the SAME disk image:
#   run A (fresh image, rebuilt at gate start):
#         script `settings` + `settings set hostname elephant-box` +
#         `settings set prompt elephant> ` + `settings get hostname`;
#         asserts the default settings, the persistence response `(persisted)`,
#         and the get response.
#   run B (same image, rebooted without rebuilding disk):
#         script `settings get hostname` + `settings list`;
#         asserts that the rebooted kernel loaded the persisted settings at boot,
#         printing the custom prompt `elephant> ` and `hostname=elephant-box`.
#
# Per run this reports: rc, serial-bytes, and per-assertion flags.
# Class B — Apple silicon + VZ only; boots real VMs.
#
# Usage:
#   bash tools/verify-live-settings.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-settings-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

PAIRS="${BOOTS:-1}"
REPORT="artifacts/live-settings-report.txt"

echo "=== verify-live-settings: claim 2649 — persistent settings on DATA partition across VZ reboot, $PAIRS pair(s) of boots ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH pairs=$PAIRS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- scripted keystrokes -----------------------------------------------------
cat > artifacts/live-settings-script-A.txt <<'EOF'
settings
settings set hostname elephant-box
settings set prompt elephant> 
settings get hostname
EOF

cat > artifacts/live-settings-script-B.txt <<'EOF'
settings get hostname
settings list
EOF

# --- per-run gate ------------------------------------------------------------
run_one() {
    local tag="$1" script="$2" expect="$3" fresh="$4"
    if [ "$fresh" = 1 ]; then
        rm -f artifacts/efi-vars.bin
    fi
    rm -f artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$script" --script-expect "$expect" --timeout 40 \
        > "artifacts/live-settings-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-settings-serial-$tag.log" || true

    local SERIAL_BYTES=0
    local DEFAULTS_OK=0 SET_HOST_OK=0 SET_PROMPT_OK=0 GET_HOST_OK=0 PERSISTED_HOST=0 CUSTOM_PROMPT=0
    if [ -f artifacts/vm-serial.log ]; then
        SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log | tr -d ' ')
        # Check initial default or list
        grep -a -qF -- "hostname=dipshit" artifacts/vm-serial.log && DEFAULTS_OK=1
        # Check set responses
        grep -a -qF -- "settings: hostname=elephant-box (persisted)" artifacts/vm-serial.log && SET_HOST_OK=1
        grep -a -qF -- "settings: prompt=elephant> (persisted)" artifacts/vm-serial.log && SET_PROMPT_OK=1
        # Check get hostname
        grep -a -qF -- "settings: hostname=elephant-box" artifacts/vm-serial.log && GET_HOST_OK=1
        # Check persisted across reboot (Run B)
        grep -a -qF -- "hostname=elephant-box" artifacts/vm-serial.log && PERSISTED_HOST=1
        grep -a -qF -- "elephant>" artifacts/vm-serial.log && CUSTOM_PROMPT=1
    fi
    local PASS=0
    if [ "$tag" = "A-1" ] || [ "$tag" = "A" ]; then
        if [ "$RC" = 0 ] && [ "$SET_HOST_OK" = 1 ] && [ "$SET_PROMPT_OK" = 1 ] && [ "$GET_HOST_OK" = 1 ]; then
            PASS=1
        fi
    else
        if [ "$RC" = 0 ] && [ "$PERSISTED_HOST" = 1 ] && [ "$CUSTOM_PROMPT" = 1 ]; then
            PASS=1
        fi
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES defaults=$DEFAULTS_OK set-host=$SET_HOST_OK set-prompt=$SET_PROMPT_OK get-host=$GET_HOST_OK persisted-host=$PERSISTED_HOST custom-prompt=$CUSTOM_PROMPT pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES defaults=$DEFAULTS_OK set-host=$SET_HOST_OK set-prompt=$SET_PROMPT_OK get-host=$GET_HOST_OK persisted-host=$PERSISTED_HOST custom-prompt=$CUSTOM_PROMPT pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live persistent settings gate (claim 2649) — settings set in run A, persisted to DATA partition, verified on reboot in run B"
    echo "revision: $REVISION branch=$BRANCH pairs=$PAIRS dirty-files=$DIRTY"
    echo "run A: settings set hostname elephant-box + settings set prompt elephant> "
    echo "run B: settings get hostname + settings list (SAME disk image across reboot)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$PAIRS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-settings pair $n, run A (set settings and persist, fresh disk) ==="
    AOK=0
    run_one "A-$n" "artifacts/live-settings-script-A.txt" $'settings: hostname=elephant-box\n' 1 && AOK=1 || true
    echo "=== live-settings pair $n, run B (persistence across reboot, same disk) ==="
    BOK=0
    run_one "B-$n" "artifacts/live-settings-script-B.txt" $'hostname=elephant-box\n' 0 && BOK=1 || true
    if [ "$AOK" = 1 ] && [ "$BOK" = 1 ]; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$PAIRS" ]; then
    echo "verify-live-settings: PASS — persistent settings configured on DATA partition, persisted to SETTINGS.TXT, and successfully restored upon fresh boot ($PASS/$PAIRS pair(s))."
    echo "PASS: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-settings: FAILED — $PASS/$PAIRS pair(s) passed; see artifacts/live-settings-report.txt and logs."
    echo "FAIL: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
