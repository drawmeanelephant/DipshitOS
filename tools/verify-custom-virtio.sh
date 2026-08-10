#!/usr/bin/env bash
#
# verify-custom-virtio.sh -- claims 0828/4374/9492/9737/4837 class-B gate:
# the custom-virtio transport on the macOS 27 spike device (VID 0x1af4 /
# DID 0x1082, `zig build spike-virtio`, claim 5844). Requires the macOS 27
# SDK: the runner is built with -DSPIKE.
#
# What one boot proves (all through the reusable driver in
# kernel/src/virtio_custom.zig):
#
#   * claim 0828 (queue transport + used-ring IRQ): the host delegate
#     dequeues the exact payload, echoes it back into the guest's write
#     descriptor, returnToQueue advances the used ring, and a real SPI IRQ
#     (INTID 0x45 = SPI 69) enters the claim-9746 vector.
#   * claim 4374 (ring allocator + multi-queue): four CONCURRENT in-flight
#     exchanges on queue 0 (the allocator hands out four chains), then a
#     second batch that reallocates the EXACT same head indices
#     (`cvspike: q0 heads=... recycle=1`); queue 1 is armed and kicked
#     too (`guest notified queue 1`).
#   * claim 9492 (multi-descriptor payloads): a 12,340-byte payload across
#     three device-read descriptors; the host reassembles the spans
#     (`dequeued 12340 byte(s)`) and echoes the full payload back, and the
#     guest verifies it byte-for-byte (`cvspike: q0 big n=0x3034 echo=ok`).
#   * claim 9737 (feature negotiation depth): the guest reads the full
#     64-bit device-features word, accepts VIRTIO_F_ANY_LAYOUT (bit 27)
#     and VIRTIO_F_NOTIFICATION_DATA (bit 38) when offered, and reports
#     `cvspike: feat=0x... acc=0x... nd=<1|0> al=<1|0> notify=<32|16>bit`.
#     The negotiated behavior is exercised: 32-bit notification-datum
#     kicks when NOTIFICATION_DATA is on, and the big-payload chain posts
#     its write descriptor FIRST when ANY_LAYOUT is on.
#   * claim 4837 (guest log transport): three guest log lines ride queue 1
#     (`cvspike: q1 log="cvlog-N" ack="ACK:7"`), the host echoes each to
#     its stdout (`CUSTOM-VIRTIO-LOG: cvlog-N`) and replies ACK:<len>,
#     which the guest verifies (`cvspike: q1 ok=3`).
#
# Mechanism: the runner's scripted-input mode (claim 6684) forwards `pci`
# (proving the device is on the bus + the shell is alive) and an echo after
# the terminal state; the runner exits 0 iff the echo output
# ("cvspike-shell-ok") appears in the serial log — i.e. AFTER the script
# was actually forwarded. (The "cvspike: irq=" report prints before the
# script runs, so expecting it would exit the runner before pci/echo are
# ever sent.)
#
# Per boot this reports:
#   rc               the runner's exit code
#   serial-bytes     vm-serial.log size
#   host-driver-ok / host-notified-q0 / host-notified-q1 / host-dequeued /
#   host-big / host-logs / host-returned
#   guest-ready / guest-feat / guest-q0 / guest-recycle / guest-big /
#   guest-q0ok / guest-q1 / guest-irq / pci-device / shell-echo
#
# Class B — Apple silicon + VZ + macOS 27 SDK only; boots a real VM.
#
# Usage:
#   bash tools/verify-custom-virtio.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-custom-virtio.sh
#
# Evidence saved under artifacts/: live-cvspike-gate.txt (full output),
# live-cvspike-report.txt (per-boot detail), live-cvspike-run-<NN>.txt
# (runner output incl. the host CUSTOM-VIRTIO lines),
# live-cvspike-serial-<NN>.log (vm-serial.log copy), live-cvspike-script.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-cvspike-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-cvspike-report.txt"
SCRIPT="artifacts/live-cvspike-script.txt"

echo "=== verify-custom-virtio: claims 0828/4374/9492/9737/4837 — custom-virtio transport on VZ (macOS 27), $BOOTS boot(s) ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates (class A + the SPIKE-gated Swift build) ---------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- the scripted keystrokes -------------------------------------------------
cat > "$SCRIPT" <<'EOF'
pci
echo cvspike-shell-ok
EOF

# --- THE GATE: per-boot live run, fresh variable store each ------------------
run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    # --script-expect waits for the scripted echo output (which appears
    # only after the script is forwarded) — expecting the cvspike IRQ line
    # would exit the runner before pci/echo are sent (claim 0828).
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --custom-virtio --script "$SCRIPT" --script-expect "cvspike-shell-ok" --timeout 60 \
        > "artifacts/live-cvspike-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-cvspike-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local RUN="artifacts/live-cvspike-run-$tag.txt"
    local SER="artifacts/live-cvspike-serial-$tag.log"
    local HOST_DRIVER_OK=0 HOST_NOTIFIED_Q0=0 HOST_NOTIFIED_Q1=0 HOST_DEQUEUED=0 HOST_BIG=0 HOST_LOGS=0 HOST_RETURNED=0
    local GUEST_READY=0 GUEST_FEAT=0 GUEST_Q0=0 GUEST_RECYCLE=0 GUEST_BIG=0 GUEST_Q0OK=0 GUEST_Q1=0 GUEST_IRQ=0 PCI_DEVICE=0 SHELL_ECHO=0
    [ -f artifacts/vm-serial.log ] || { SERIAL_BYTES=0; }
    # all_grep: every argument must be found in the given file — a flag is
    # set only when the WHOLE assertion group matches (the per-grep `&&`
    # idiom would pass on a single match).
    all_grep() { # $1 = file, rest = fixed strings
        local f="$1" pat
        shift
        for pat in "$@"; do grep -qF -- "$pat" "$f" || return 1; done
        return 0
    }
    if [ -f "$RUN" ]; then
        all_grep "$RUN" "CUSTOM-VIRTIO: guest set DRIVER_OK" && HOST_DRIVER_OK=1
        all_grep "$RUN" "CUSTOM-VIRTIO: guest notified queue 0" && HOST_NOTIFIED_Q0=1
        all_grep "$RUN" "CUSTOM-VIRTIO: guest notified queue 1" && HOST_NOTIFIED_Q1=1
        all_grep "$RUN" "CUSTOM-VIRTIO: dequeued 16 byte(s)" 'ascii="DIPSHITOS-CV0x42"' && HOST_DEQUEUED=1
        # Claim 9492: the host reassembled the three read spans into the
        # full 12,340-byte payload (readBuffersByteCount matches).
        all_grep "$RUN" "CUSTOM-VIRTIO: dequeued 12340 byte(s) (read 12340)" && HOST_BIG=1
        # Claim 4837: every guest log line reached the runner stdout.
        all_grep "$RUN" "CUSTOM-VIRTIO-LOG: cvlog-1" "CUSTOM-VIRTIO-LOG: cvlog-2" "CUSTOM-VIRTIO-LOG: cvlog-3" && HOST_LOGS=1
        all_grep "$RUN" "CUSTOM-VIRTIO: returned element" && HOST_RETURNED=1
    fi
    if [ -f "$SER" ]; then
        all_grep "$SER" "cvspike: init ok" "cvspike: dev=" 'cvspike: payload="DIPSHITOS-CV0x42"' && GUEST_READY=1
        # Claim 9737: the feature report structure (feat/acc words, the
        # per-feature flags, and the negotiated kick width).
        all_grep "$SER" "cvspike: feat=0x" " acc=0x" " nd=" " al=" " notify=" && GUEST_FEAT=1
        # Claim 4374: all four in-flight exchanges echoed verbatim, and the
        # second batch reallocated the exact same head indices (the LIFO
        # free list: 31,29,27,25) — the deterministic recycle proof.
        all_grep "$SER" "cvspike: q0 xchg=1 n=0x10 echo=ok" \
            "cvspike: q0 xchg=2 n=0x10 echo=ok" \
            "cvspike: q0 xchg=3 n=0x10 echo=ok" \
            "cvspike: q0 xchg=4 n=0x10 echo=ok" \
            "cvspike: q0 heads=0x0000000000000000,0x0000000000000002,0x0000000000000004,0x0000000000000006 recycle=1" && GUEST_Q0=1
        all_grep "$SER" "cvspike: q0 heads=0x0000000000000000,0x0000000000000002,0x0000000000000004,0x0000000000000006 recycle=1" && GUEST_RECYCLE=1
        # Claim 9492: the 12,340-byte payload came back byte-for-byte.
        all_grep "$SER" "cvspike: q0 big n=0x3034 echo=ok" && GUEST_BIG=1
        all_grep "$SER" "cvspike: q0 ok=1" && GUEST_Q0OK=1
        # Claim 4837: every log line echoed with a verified ACK.
        all_grep "$SER" 'cvspike: q1 log="cvlog-1" ack="ACK:7" n=0x0000000000000005' \
            'cvspike: q1 log="cvlog-2" ack="ACK:7" n=0x0000000000000005' \
            'cvspike: q1 log="cvlog-3" ack="ACK:7" n=0x0000000000000005' \
            "cvspike: q1 ok=3" && GUEST_Q1=1
        all_grep "$SER" "cvspike: irq=" "first=0x0000000000000045" && GUEST_IRQ=1
        all_grep "$SER" "DID=0x0000000000001082" && PCI_DEVICE=1
        all_grep "$SER" "cvspike-shell-ok" && SHELL_ECHO=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES host-driver-ok=$HOST_DRIVER_OK host-notified-q0=$HOST_NOTIFIED_Q0 host-notified-q1=$HOST_NOTIFIED_Q1 host-dequeued=$HOST_DEQUEUED host-big=$HOST_BIG host-logs=$HOST_LOGS host-returned=$HOST_RETURNED guest-ready=$GUEST_READY guest-feat=$GUEST_FEAT guest-q0=$GUEST_Q0 guest-recycle=$GUEST_RECYCLE guest-big=$GUEST_BIG guest-q0ok=$GUEST_Q0OK guest-q1=$GUEST_Q1 guest-irq=$GUEST_IRQ pci-device=$PCI_DEVICE shell-echo=$SHELL_ECHO"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES host-driver-ok=$HOST_DRIVER_OK host-notified-q0=$HOST_NOTIFIED_Q0 host-notified-q1=$HOST_NOTIFIED_Q1 host-dequeued=$HOST_DEQUEUED host-big=$HOST_BIG host-logs=$HOST_LOGS host-returned=$HOST_RETURNED guest-ready=$GUEST_READY guest-feat=$GUEST_FEAT guest-q0=$GUEST_Q0 guest-recycle=$GUEST_RECYCLE guest-big=$GUEST_BIG guest-q0ok=$GUEST_Q0OK guest-q1=$GUEST_Q1 guest-irq=$GUEST_IRQ pci-device=$PCI_DEVICE shell-echo=$SHELL_ECHO"
    # The gate passes iff every link of the transport proved itself: host
    # side (DRIVER_OK, both queues notified, small + big payloads dequeued,
    # log lines echoed, elements returned) and guest side (init, feature
    # report, in-flight echoes, recycle, big-payload byte-for-byte verify,
    # log acks, the real SPI IRQ) with the shell alive (polled console
    # paths preserved).
    [ "$RC" = 0 ] && [ "$HOST_DRIVER_OK" = 1 ] && [ "$HOST_NOTIFIED_Q0" = 1 ] && [ "$HOST_NOTIFIED_Q1" = 1 ] && [ "$HOST_DEQUEUED" = 1 ] && [ "$HOST_BIG" = 1 ] && [ "$HOST_LOGS" = 1 ] && [ "$HOST_RETURNED" = 1 ] && [ "$GUEST_READY" = 1 ] && [ "$GUEST_FEAT" = 1 ] && [ "$GUEST_Q0" = 1 ] && [ "$GUEST_RECYCLE" = 1 ] && [ "$GUEST_BIG" = 1 ] && [ "$GUEST_Q0OK" = 1 ] && [ "$GUEST_Q1" = 1 ] && [ "$GUEST_IRQ" = 1 ] && [ "$PCI_DEVICE" = 1 ] && [ "$SHELL_ECHO" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS custom-virtio gate (claims 0828/4374/9492/9737/4837) — queue transport + used-ring IRQ + ring allocator + multi-queue + multi-descriptor payloads + feature negotiation + log transport on VZ (macOS 27)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $SCRIPT (pci / echo cvspike-shell-ok; expect the cvspike report in the serial log)"
    echo "host evidence source: runner stdout (CUSTOM-VIRTIO lines in live-cvspike-run-*.txt)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-cvspike boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-custom-virtio: PASS — the full custom-virtio transport proved itself on $PASS/$BOOTS boot(s): queue transport + used-ring IRQ (SPI 69), four concurrent in-flight exchanges with descriptor recycling, a 12,340-byte multi-descriptor payload reassembled + echoed byte-for-byte, the negotiated feature report (ANY_LAYOUT / NOTIFICATION_DATA), and the guest log transport (queue 1) with host echo, with the shell alive on every boot."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-custom-virtio: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-cvspike-report.txt and the per-boot run/serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
