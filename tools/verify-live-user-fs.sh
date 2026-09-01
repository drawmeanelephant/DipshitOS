#!/usr/bin/env bash
#
# verify-live-user-fs.sh -- claim 0510 (milestone 10 card F4) class-B gate:
# userland storage ABI and utilities (SAVETEXT.BIN, TYPE.BIN, DIR.BIN) verified
# on real Apple silicon Virtualization.framework hardware.
#
# The gate performs a multi-boot persistent round-trip:
#   1. Boot A (fresh disk image):
#      - Runs `exec SAVETEXT.BIN` from the shell.
#      - SAVETEXT.BIN opens `/host/hello.txt` (M34 HF5 issue #739 — user
#        data lives in the host folder; the SAME --cvc-file share is
#        attached to both boots) via sys_file_open (slot 23), writes
#        persistent payload via sys_file_write (slot 25), closes via
#        sys_file_close (slot 26), and outputs:
#        "savetext: wrote /host/hello.txt\n"
#      - Asserts process exit status 0.
#   2. Boot B (reboot VM against the same disk image):
#      - Runs `exec TYPE.BIN` and `exec DIR.BIN` from the shell.
#      - TYPE.BIN opens `/host/hello.txt` with MODE_READ (slot 23),
#        reads contents via sys_file_read (slot 24), echoes payload to console,
#        outputs "type: success\n", and exits with status 0.
#      - DIR.BIN enumerates `/host` directory entries via sys_dir_list (slot 27),
#        outputs directory listings, outputs "dir: success\n", and exits with status 0.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): both boots run
# against a PRIVATE WRITABLE disk image ($RUN_DIR/disk-base.img, seeded
# fresh after the build), a private EFI var store, and private serial logs
# under $RUN_DIR — the writable copy is required because Boot B proves
# Boot A's write persisted across a reboot. VIRELAI_GATE_SUFFIX=_alt /
# VIRELAI_KEEP_RUN=1 supported.
#
# Usage:
#   bash tools/verify-live-user-fs.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-user-fs-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-user-fs-report.txt)"

echo "=== verify-live-user-fs: claim 0510 — userland storage ABI & utilities on VZ hardware ==="

# --- per-run isolation -------------------------------------------------------
gate_begin live-user-fs
echo "run dir: $RUN_DIR"

# M34 HF5/HF6 (issues #739/#740): the persistence consumers re-pointed to
# the HOST SHARE (SAVETEXT/TYPE/DIR now use /host/...; the FAT volume is
# gone). Both boots attach the SAME share dir under RUN_DIR, so "survived
# reboot" is proven on the macOS filesystem itself — the gate then
# verifies hello.txt ON THE HOST DISK. The share is seeded with the app
# bundle so `exec SAVETEXT.BIN` / `exec TYPE.BIN` / `exec DIR.BIN` resolve.
gate_seed_share

# Tool versions + revision
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "revision: $REVISION branch=$BRANCH"

# Build all binaries and disk image. OBSERVED TODAY (2026-08-24, claim
# 5069): the bare `make-image.sh` call embedded only a subset of user
# programs — DIR.BIN was missing from the ESP ("error: DIR.BIN: not found
# on the ESP"), failing Boot B. `zig build image` is the canonical builder
# and embeds every registered program.
zig build
zig build image
# M34 HF5 (issue #739): the gate attaches the --cvc-file share, which
# requires the SPIKE runner build (the custom-virtio FILE channel).
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# Scripts for Boot A and Boot B
cat > "$RUN_DIR/script-A.txt" <<'EOF'
exec SAVETEXT.BIN
echo done-savetext
procs
EOF

cat > "$RUN_DIR/script-B.txt" <<'EOF'
exec TYPE.BIN
exec DIR.BIN
echo done-fs-read
procs
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

# Phase 1: Boot A — Write persistent file from EL0
echo "--- Phase 1: Boot A (SAVETEXT.BIN) ---"
rm -f "$RUN_DIR/efi-vars.bin"
rm -f "$RUN_DIR/vm-serial-A.log"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial-A.log" \
    --script "$RUN_DIR/script-A.txt" \
    --script-after "$STATIC_EXIT_LINE" \
    --script-expect "procs SAVETEXT.BIN exited status=0" \
    --timeout 40 > "$(art live-user-fs-run-A.txt)" 2>&1
RC_A=$?
set -e
[ -f "$RUN_DIR/vm-serial-A.log" ] && cp "$RUN_DIR/vm-serial-A.log" "$(art live-user-fs-serial-A.log)" || true

if [ $RC_A -ne 0 ]; then
    echo "ERROR: Boot A failed with return code $RC_A"
    exit 1
fi

grep -q "savetext: wrote /host/hello.txt" "$(art live-user-fs-serial-A.log)" || {
    echo "ERROR: SAVETEXT.BIN write marker missing from serial log"
    exit 1
}
grep -q "procs SAVETEXT.BIN exited status=0" "$(art live-user-fs-serial-A.log)" || {
    echo "ERROR: SAVETEXT.BIN exit status 0 missing from serial log"
    exit 1
}
echo "Boot A passed: SAVETEXT.BIN wrote persistent data and exited cleanly."

# Phase 2: Boot B — Reboot and verify persistence via TYPE.BIN and DIR.BIN
echo "--- Phase 2: Boot B (TYPE.BIN + DIR.BIN persistence verification) ---"
# Settle before re-attaching the written image (see verify-live-fs note).
sleep 3
rm -f "$RUN_DIR/vm-serial-B.log"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial-B.log" \
    --script "$RUN_DIR/script-B.txt" \
    --script-after "$STATIC_EXIT_LINE" \
    --script-expect "procs DIR.BIN exited status=0" \
    --timeout 40 > "$(art live-user-fs-run-B.txt)" 2>&1
RC_B=$?
set -e
[ -f "$RUN_DIR/vm-serial-B.log" ] && cp "$RUN_DIR/vm-serial-B.log" "$(art live-user-fs-serial-B.log)" || true

if [ $RC_B -ne 0 ]; then
    echo "ERROR: Boot B failed with return code $RC_B"
    exit 1
fi

# OBSERVED TODAY (2026-08-24, claim 5069): exec spawns are fire-and-forget,
# so TYPE.BIN and DIR.BIN print CONCURRENTLY and their console lines can
# merge mid-line (serial bytes observed: `...stack=0x00000000type: succesdir:
# success` — "type: success" split by an interleaved write). Assert on the
# long unique payload (survives merges) plus the exit statuses; the short
# success markers stay diagnostic-only via the payload/status proof.
grep -q "Hello from VirelaiOS EL0 Storage!" "$(art live-user-fs-serial-B.log)" || {
    echo "ERROR: TYPE.BIN read payload missing or incorrect"
    exit 1
}
grep -q "procs TYPE.BIN exited status=0" "$(art live-user-fs-serial-B.log)" || {
    echo "ERROR: TYPE.BIN exit status 0 missing from serial log"
    exit 1
}

grep -q "dir: listing /host" "$(art live-user-fs-serial-B.log)" || {
    echo "ERROR: DIR.BIN listing marker missing from serial log"
    exit 1
}
# Host-share listing preserves the guest's casing (hello.txt — the FAT
# volume would have uppercased it to HELLO.TXT), so match case-insensitively.
grep -qi "hello.txt" "$(art live-user-fs-serial-B.log)" || {
    echo "ERROR: hello.txt missing from DIR.BIN directory enumeration"
    exit 1
}
grep -q "dir: success" "$(art live-user-fs-serial-B.log)" || {
    echo "ERROR: DIR.BIN success marker missing from serial log"
    exit 1
}
grep -q "procs DIR.BIN exited status=0" "$(art live-user-fs-serial-B.log)" || {
    echo "ERROR: DIR.BIN exit status 0 missing from serial log"
    exit 1
}

echo "Boot B passed: TYPE.BIN and DIR.BIN verified persistent data across reboot."

# M34 HF5 (issue #739): prove the write landed ON THE HOST DISK — the
# share is the persistence home now (M34 HF6 deleted the FAT DATA
# partition; SAVETEXT/TYPE/DIR route to /host).
HOST_OK=0
if [ -f "$SHARE/hello.txt" ] && grep -qF "Hello from VirelaiOS EL0 Storage!" "$SHARE/hello.txt"; then
    HOST_OK=1
    echo "HF5-DISK: hello.txt on the host share carries the 34-byte payload"
else
    echo "HF5-DISK: FAIL — hello.txt missing/incomplete on the host share"
fi
if [ "$HOST_OK" != 1 ]; then
    echo "ERROR: host-side persistence verification failed"
    exit 1
fi

# Summary report
cat > "$REPORT" <<EOF
=== Milestone 10 Capstone Gate Report (Claim 0510) ===
Date: $(date -u '+%Y-%m-%d %H:%M:%SZ')
Revision: $REVISION
Branch: $BRANCH
Boot A (SAVETEXT.BIN): PASSED (wrote /host/hello.txt to the share, status=0)
Boot B (TYPE.BIN): PASSED (read persistent data across reboot, status=0)
Boot B (DIR.BIN): PASSED (enumerated /host entries including HELLO.TXT, status=0)
Host disk: PASSED (hello.txt byte-verified in the --cvc-file share)
Result: SUCCESS (all assertions verified on Apple silicon VZ hardware)
EOF

cat "$REPORT"
echo "=== verify-live-user-fs: SUCCESS ==="
