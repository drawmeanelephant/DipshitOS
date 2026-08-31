#!/usr/bin/env bash
#
# verify-cvc-echo.sh -- claim 3141 class-B gate (issue #523 item 3, first
# working end-to-end spike of a host-implemented virtio device): ONE
# deterministic HOST-initiated round trip through the macOS 27
# VZCustomVirtioDevice,
#
#   host app enqueues -> guest driver receives -> guest replies ->
#   host delegate observes,
#
# asserted with BYTE-EXACT expectations on both sides.
#
# Why a pre-armed buffer: the Xcode 27 SDK exposes NO host-side enqueue —
# VZVirtioQueue elements exist only as descriptors the GUEST posted
# (VZVirtioQueue.nextElement is the only dequeue; VZVirtioQueueElement has no
# constructor). The virtio-standard pattern (virtio-net RX) is therefore:
# the guest driver pre-arms ONE empty device-write receive buffer on queue 2
# (`--cvc-echo` attaches the device with THREE queues; plain
# --custom-virtio stays two-queue — the queue count IS the capability
# signal), signals readiness over the existing queue-1 log transport
# ("cvc-push-armed"), and the HOST delegate enqueues the request at a moment
# of ITS choosing when it processes that line (event-driven, no timing
# dance). returnToQueue advances the used ring + asserts the device SPI —
# the framework's only host->guest signaling.
#
# Byte-exact protocol on queue 2 ("push echo"):
#   request  host -> guest : "CVC-PING-0x42"  (13 bytes)
#   reply    guest -> host : "CVC-PING-0x42"  (verbatim echo)
#   ack      host -> guest : "OK:13"
#
# Per boot this asserts, ALL byte-exact:
#   host side (runner stdout): DRIVER_OK, the armed-signal log line echoed,
#     the enqueue line, and the byte-exact reply verification + OK:13 ack;
#   guest side (serial log):   transport init, the q2 armed/handle report,
#     req="CVC-PING-0x42" n=0x000000000000000d req=ok handle=ok,
#     rsp="CVC-PING-0x42" ack="OK:13" ok=1, the q2 ok=1 summary, the classic
#     queue-0/queue-1 transports in the SAME boot (q0 ok=1, q1 ok=3), the
#     real used-ring SPI IRQ, and the shell alive after the exchange
#     (scripted pci + echo forwarded once the terminal state appears).
#
# Class B — Apple silicon + VZ + macOS 27 SDK only; boots a real VM.
#
# Usage:
#   bash tools/verify-cvc-echo.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-cvc-echo.sh
#
# Evidence saved under artifacts/: live-cvc-gate.txt (full output),
# live-cvc-report.txt (per-boot detail), live-cvc-run-<NN>.txt (runner
# output incl. the host CUSTOM-VIRTIO/CUSTOM-VIRTIO-PUSH lines),
# live-cvc-serial-<NN>.log (vm-serial.log copy), live-cvc-script.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-cvc-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-cvc-report.txt"
SCRIPT="artifacts/live-cvc-script.txt"

echo "=== verify-cvc-echo: claim 3141 — HOST-initiated custom-virtio round trip on VZ (macOS 27), $BOOTS boot(s) ==="

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
echo cvc-shell-ok
EOF

# --- THE GATE: per-boot live run, fresh variable store each ------------------
run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    # --script-expect waits for the scripted echo output (which appears
    # only after the script is forwarded) — same choreography as
    # verify-custom-virtio.sh (claim 0828).
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --cvc-echo --script "$SCRIPT" --script-expect "cvc-shell-ok" --timeout 60 \
        > "artifacts/live-cvc-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-cvc-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local RUN="artifacts/live-cvc-run-$tag.txt"
    local SER="artifacts/live-cvc-serial-$tag.log"
    local H_DRIVER_OK=0 H_ARMED_LOG=0 H_ENQUEUE=0 H_VERIFIED=0
    local G_INIT=0 G_ARMED=0 G_REQ=0 G_RSP=0 G_Q2=0 G_Q0=0 G_Q1=0 G_IRQ=0 PCI_DEVICE=0 SHELL_ECHO=0
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
        all_grep "$RUN" "CUSTOM-VIRTIO: guest set DRIVER_OK" && H_DRIVER_OK=1
        # The armed signal rode queue 1 and the host echoed it before pushing.
        all_grep "$RUN" "CUSTOM-VIRTIO-LOG: cvc-push-armed" && H_ARMED_LOG=1
        all_grep "$RUN" 'CUSTOM-VIRTIO-PUSH: host enqueued req="CVC-PING-0x42" (13 byte(s)) into the pre-armed rx buffer' && H_ENQUEUE=1
        all_grep "$RUN" 'CUSTOM-VIRTIO-PUSH: reply verified rsp="CVC-PING-0x42" (byte-exact), wrote ack="OK:13"' && H_VERIFIED=1
    fi
    if [ -f "$SER" ]; then
        all_grep "$SER" "cvspike: init ok" && G_INIT=1
        all_grep "$SER" "cvspike: q2 armed rx=1 handle=" && G_ARMED=1
        all_grep "$SER" 'cvspike: q2 req="CVC-PING-0x42" n=0x000000000000000d req=ok handle=ok' && G_REQ=1
        all_grep "$SER" 'cvspike: q2 rsp="CVC-PING-0x42" ack="OK:13" ok=1' && G_RSP=1
        all_grep "$SER" "cvspike: q2 ok=1" && G_Q2=1
        # The classic transports must still work in the same boot: the
        # queue-0 exchanges and the three queue-1 log lines.
        all_grep "$SER" "cvspike: q0 ok=1" && G_Q0=1
        all_grep "$SER" "cvspike: q1 ok=3" && G_Q1=1
        all_grep "$SER" "cvspike: irq=" "first=0x0000000000000045" && G_IRQ=1
        all_grep "$SER" "DID=0x0000000000001082" && PCI_DEVICE=1
        all_grep "$SER" "cvc-shell-ok" && SHELL_ECHO=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES host-driver-ok=$H_DRIVER_OK host-armed-log=$H_ARMED_LOG host-enqueue=$H_ENQUEUE host-verified=$H_VERIFIED guest-init=$G_INIT guest-armed=$G_ARMED guest-req=$G_REQ guest-rsp=$G_RSP guest-q2=$G_Q2 guest-q0=$G_Q0 guest-q1=$G_Q1 guest-irq=$G_IRQ pci-device=$PCI_DEVICE shell-echo=$SHELL_ECHO"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES host-driver-ok=$H_DRIVER_OK host-armed-log=$H_ARMED_LOG host-enqueue=$H_ENQUEUE host-verified=$H_VERIFIED guest-init=$G_INIT guest-armed=$G_ARMED guest-req=$G_REQ guest-rsp=$G_RSP guest-q2=$G_Q2 guest-q0=$G_Q0 guest-q1=$G_Q1 guest-irq=$G_IRQ pci-device=$PCI_DEVICE shell-echo=$SHELL_ECHO"
    # The gate passes iff every link of the HOST-initiated round trip proved
    # itself byte-exactly AND the classic transports stayed green in the
    # same boot, with the shell alive at the end.
    [ "$RC" = 0 ] && [ "$H_DRIVER_OK" = 1 ] && [ "$H_ARMED_LOG" = 1 ] && [ "$H_ENQUEUE" = 1 ] && [ "$H_VERIFIED" = 1 ] && [ "$G_INIT" = 1 ] && [ "$G_ARMED" = 1 ] && [ "$G_REQ" = 1 ] && [ "$G_RSP" = 1 ] && [ "$G_Q2" = 1 ] && [ "$G_Q0" = 1 ] && [ "$G_Q1" = 1 ] && [ "$G_IRQ" = 1 ] && [ "$PCI_DEVICE" = 1 ] && [ "$SHELL_ECHO" = 1 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS cvc-echo gate (claim 3141) — HOST-initiated custom-virtio round trip (host app enqueues -> guest receives -> guest replies -> host delegate observes) on VZ (macOS 27)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $SCRIPT (pci / echo cvc-shell-ok)"
    echo "host evidence source: runner stdout (CUSTOM-VIRTIO / CUSTOM-VIRTIO-PUSH lines in live-cvc-run-*.txt)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-cvc boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-cvc-echo: PASS — the HOST-initiated round trip proved itself on $PASS/$BOOTS boot(s): the guest pre-armed its receive buffer and signaled readiness over queue 1; the host app enqueued \"CVC-PING-0x42\" at a moment of its choosing; the guest received all 13 bytes (req=ok handle=ok), replied verbatim, and verified the host's OK:13 ack; the host delegate confirmed the byte-exact reply and wrote the ack — with the classic queue-0/queue-1 transports and the used-ring SPI IRQ green in the same boot and the shell alive."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-cvc-echo: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-cvc-report.txt and the per-boot run/serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
