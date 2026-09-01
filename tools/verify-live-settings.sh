#!/usr/bin/env bash
#
# verify-live-settings.sh -- claim 2649 (milestone-eight card U8) class-B gate:
# PERSISTENT SETTINGS observed across reboot on real Virtualization.framework hardware.
#
# Card U8 contract (ADR 0008 Card U8):
#   - In-memory key-value store backed by `SETTINGS.TXT` on the HOST SHARE
#     (M34 HF6 deleted the DATA FAT32 partition; the kernel settings engine
#     re-pointed to the queue-5 channel).
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
# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set VIRELAI_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# VIRELAI_KEEP_RUN=1 to keep the scratch dir.
#
# Class B — Apple silicon + VZ only; boots real VMs.
#
# Usage:
#   bash tools/verify-live-settings.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-settings-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

PAIRS="${BOOTS:-1}"
REPORT="$(art live-settings-report.txt)"

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
# M34 HF5 (issue #739): the gate attaches the --cvc-file share, which
# requires the SPIKE runner build (the custom-virtio FILE channel).
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-settings
echo "run dir: $RUN_DIR"

# M34 HF5/HF6 (issues #739/#740): settings persist to the HOST SHARE (the
# kernel settings engine re-pointed: SETTINGS.TXT lives in the --cvc-file
# folder; the FAT volume is gone). Both boots attach the SAME share dir,
# so "across reboot" is proven on the macOS filesystem itself, and the
# gate verifies SETTINGS.TXT on the host disk after run B.
gate_arm_share

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
        rm -f "$RUN_DIR/efi-vars.bin"
    fi
    rm -f "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$script" --script-expect "$expect" --timeout 40 \
        > "$(art live-settings-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-settings-serial-$tag.log)" || true
    local SER="$(art live-settings-serial-$tag.log)"

    local SERIAL_BYTES=0
    local DEFAULTS_OK=0 SET_HOST_OK=0 SET_PROMPT_OK=0 GET_HOST_OK=0 PERSISTED_HOST=0 CUSTOM_PROMPT=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" | tr -d ' ')
        # Check initial default or list
        grep -a -qF -- "hostname=virelai" "$SER" && DEFAULTS_OK=1
        # Check set responses
        grep -a -qF -- "settings: hostname=elephant-box (persisted)" "$SER" && SET_HOST_OK=1
        grep -a -qF -- "settings: prompt=elephant> (persisted)" "$SER" && SET_PROMPT_OK=1
        # Check get hostname
        grep -a -qF -- "settings: hostname=elephant-box" "$SER" && GET_HOST_OK=1
        # Check persisted across reboot (Run B)
        grep -a -qF -- "hostname=elephant-box" "$SER" && PERSISTED_HOST=1
        grep -a -qF -- "elephant>" "$SER" && CUSTOM_PROMPT=1
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
    echo "VIRELAIOS live persistent settings gate (claim 2649) — settings set in run A, persisted to DATA partition, verified on reboot in run B"
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

# M34 HF5 (issue #739): verify the settings file ON THE HOST DISK — the
# share is the persistence home now.
HOST_OK=0
if [ -f "$SHARE/SETTINGS.TXT" ] && grep -q 'hostname=elephant-box' "$SHARE/SETTINGS.TXT" && grep -q 'prompt=elephant>' "$SHARE/SETTINGS.TXT"; then
    HOST_OK=1
    echo "HF5-DISK: SETTINGS.TXT on the host share carries hostname=elephant-box + prompt=elephant>"
else
    echo "HF5-DISK: FAIL — SETTINGS.TXT missing/incomplete on the host share"
fi

echo
echo "=== result ==="
if [ "$PASS" = "$PAIRS" ] && [ "$HOST_OK" = 1 ]; then
    echo "verify-live-settings: PASS — persistent settings configured on the HOST SHARE, persisted to SETTINGS.TXT (host-verified), and successfully restored upon fresh boot ($PASS/$PAIRS pair(s))."
    echo "PASS: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-settings: FAILED — $PASS/$PAIRS pair(s) passed; see artifacts/live-settings-report.txt and logs."
    echo "FAIL: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
