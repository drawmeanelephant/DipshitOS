#!/usr/bin/env bash
#
# gate-run.sh -- per-run isolation for live (class-B) gates.
# Issue #523 item 2, claim 6637. Source this from a verify-live-* script:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/gate-run.sh"   # from tools/
#   gate_begin live-net-tcp
#   ... run VMRunner with "${GATE_RUNNER_ARGS[@]}", --serial "$RUN_DIR/vm-serial.log",
#       scratch files under "$RUN_DIR", evidence copied back to artifacts/ ...
#   gate_end
#
# gate_begin NAME:
#   - creates a private RUN_DIR (mktemp -d); two concurrent runs of the same
#     or different gates never share writable state;
#   - seeds $RUN_DIR/disk-base.img + efi-vars.bin from artifacts/;
#   - fills GATE_RUNNER_ARGS: --overlay-base <base> --vars <vars>
#     (macOS 27 DiskImageKit stacked image — the VM boots a pristine disk
#     read-only base; guest writes land in a throwaway ASIF overlay the
#     runner deletes at exit).
# gate_end:
#   - removes RUN_DIR unless DIPSHIT_KEEP_RUN=1 (post-mortem escape hatch).
#
# Evidence policy: copy what you need back into artifacts/ BEFORE gate_end
# using the gate's canonical names. Two concurrent instances of the SAME
# gate may race on those canonical copies (last writer wins) but can no
# longer corrupt each other's runs.

set -euo pipefail

RUN_DIR=""
GATE_NAME=""
GATE_RUNNER_ARGS=()

gate_begin() {
    GATE_NAME="$1"
    # Base directory is overridable for experiments/debugging:
    #   DIPSHIT_RUN_DIR_BASE=<dir>  (default: ${TMPDIR:-/tmp})
    local base="${DIPSHIT_RUN_DIR_BASE:-${TMPDIR:-/tmp}}"
    mkdir -p "$base"
    RUN_DIR="$(mktemp -d "$base/dipshit-${GATE_NAME}.XXXXXX")"
    # APFS clonefile when available: preserves the source image's extent
    # personality (observed 2026-08-24, claim 5069 — see notes in
    # verify-live-scripting.sh about guest FAT writes on copied images).
    cp -c artifacts/disk.img "$RUN_DIR/disk-base.img" 2>/dev/null || cp artifacts/disk.img "$RUN_DIR/disk-base.img"
    if [ -f artifacts/efi-vars.bin ]; then
        cp artifacts/efi-vars.bin "$RUN_DIR/efi-vars.bin"
    else
        : > "$RUN_DIR/efi-vars.bin"
    fi
    GATE_RUNNER_ARGS=(--overlay-base "$RUN_DIR/disk-base.img" --vars "$RUN_DIR/efi-vars.bin")
}

gate_end() {
    [ -n "$RUN_DIR" ] || return 0
    if [ "${DIPSHIT_KEEP_RUN:-0}" = "1" ]; then
        echo "gate-run: keeping $RUN_DIR (DIPSHIT_KEEP_RUN=1)"
    else
        rm -rf "$RUN_DIR"
    fi
    RUN_DIR=""
}

# --- shared-disk mode --------------------------------------------------------
# OBSERVED 2026-08-24 (claim 5069, macOS 27.0 build 26A5416b): guest FAT
# writes are unreliable when the VM attaches a FRESH COPY of the built
# image ("not persisted - no disk", un-bootable images, GPT-region churn)
# while writes to the long-lived artifacts/disk.img behave like main.
# Until that platform defect is understood, gates whose scripts WRITE to
# disk boot the canonical image under this advisory lock so two instances
# never attach it simultaneously (mkdir spin-lock: crash-safe, no flock(1)
# on macOS).
GATE_DISK_LOCK=".build/gate-disk.lock"
gate_shared_disk_lock() {
    # The lock lives under .build/, which a fresh worktree may not have yet
    # (observed 2026-08-24, claim 2259: without this, mkdir fails forever
    # and every caller spins until the 600s takeover).
    mkdir -p -- "$(dirname -- "$GATE_DISK_LOCK")"
    local waited=0
    while ! mkdir "$GATE_DISK_LOCK" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 600 ]; then
            echo "gate-run: WARNING — disk lock wait exceeded 600s, taking over" >&2
            rm -rf "$GATE_DISK_LOCK"
            return 1
        fi
    done
}
gate_shared_disk_unlock() {
    rmdir "$GATE_DISK_LOCK" 2>/dev/null || true
}
