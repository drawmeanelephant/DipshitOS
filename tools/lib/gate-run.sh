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
    RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dipshit-${GATE_NAME}.XXXXXX")"
    cp artifacts/disk.img "$RUN_DIR/disk-base.img"
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
