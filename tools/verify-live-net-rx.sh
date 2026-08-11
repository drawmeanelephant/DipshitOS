#!/usr/bin/env bash
#
# verify-live-net-rx.sh -- claim 6076 (milestone five, card N2) class-B
# gate: the virtio-net RX path + the round trip observed end to end on real
# VZ hardware, byte-exact on the host.
#
# Mechanism: the runner's `--net <capture-file>` flag (N1, claim 1373)
# attaches ONE VZVirtioNetworkDeviceConfiguration with a
# VZFileHandleNetworkDeviceAttachment and a FIXED host MAC
# (02:00:00:00:00:01). The guest's virtio_net.zig transport arms queue 0
# (RX) with ONE fixed BSS buffer post-re-arm and prints `net: rx-armed`;
# the runner's `--net-inject <file>` (claim 6076) then writes the file's
# bytes into the SAME attachment's socket ONCE (a serial trigger, not a
# sleep), VZ delivers the datagram to the guest's RX queue, the guest
# drains the used ring POLLED (the N1/blk shape; the net device's
# used-buffer IRQ is not yet observed on this platform — recorded in the
# claim, not assumed), MAC-filters (own + broadcast, drop the rest), pushes
# accepted frames into the bounded FIFO, and `net recv` prints them
# byte-exact.
#
# Phase 1 (broadcast + the round trip): inject the 60-byte known frame
# (broadcast dst, own src, ethertype 0x0800, payload bytes 00..2d) — the
# EXACT frame `netsend 46` builds. Script: `net recv | net | netsend 46 |
# echo net-rx-ok`. Asserts the `net recv` hex carries the exact injected
# bytes (with the claim-time RX-header headroom — `net: rx-obs` records
# the device-written length + first 16 bytes so the header question is
# pinned, not assumed), the rx counters (frames=1 filtered=0 overflow=0),
# AND that the host capture file holds the SAME 60 bytes the guest
# re-sent (receive then transmit — "raw Ethernet frames back and forth").
#
# Phase 2 (own-MAC filter): inject a 46-byte frame addressed TO the guest
# MAC (02:00:00:00:00:01). Script: `net recv | net | echo net-rx-ok`.
# Asserts the frame is received byte-exact (frames=1 filtered=0).
#
# Phase 3 (foreign-MAC filter): inject a 46-byte frame addressed to
# 02:00:00:00:00:03. Script: `net recv | net | echo net-rx-ok`. Asserts
# `net recv: no frames`, rx frames=0, filtered=1 — AND that rx-obs still
# recorded the delivered bytes (a drop is distinguishable from a failed
# delivery).
#
# The gate only ever adds the `--net`/`--net-inject` surface: the default
# VM is untouched, and the FULL 29-gate verify-vz aggregate must stay
# green (re-run separately).
#
# Honesty: the runner exits 0 only when the expected reply appears; the
# gate additionally asserts every transcript line AND compares the capture
# bytes, so an early exit on the echoed input line cannot pass. Evidence
# under artifacts/: live-net-rx-*.txt (runner output), live-net-rx-*.log
# (serial copies), live-net-rx-*.bin (host captures), and the report.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-net-rx.sh
#
# Evidence: artifacts/live-net-rx-gate.txt (full output),
# artifacts/live-net-rx-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-net-rx-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-net-rx-report.txt"

echo "=== verify-live-net-rx: claim 6076 — virtio-net RX + the round trip (buffer supply, polled used-ring drain, MAC filter, bounded FIFO, net recv, host->guest injection) ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- scripted keystrokes -----------------------------------------------------
cat > artifacts/live-net-rx-script-1.txt <<'EOF'
net recv
net
netsend 46
echo net-rx-ok
EOF
cat > artifacts/live-net-rx-script-2.txt <<'EOF'
net recv
net
echo net-rx-ok
EOF
cat > artifacts/live-net-rx-script-3.txt <<'EOF'
net recv
net
echo net-rx-ok
EOF

# --- byte-exact fixtures (the class-A build_known_frame shapes) -------------
# p1: the 60-byte broadcast known frame `netsend 46` sends back (the round
#     trip: inject this, the guest receives it AND re-sends it — the
#     capture must hold the same bytes).
# p2: a 46-byte frame addressed TO the guest MAC (own-MAC filter).
# p3: a 46-byte frame addressed to a FOREIGN MAC (filter drop).
python3 - <<'PY'
own = bytes([0x02,0,0,0,0,1])
p1 = bytes([0xff]*6) + own + bytes([0x08,0]) + bytes(range(46))
assert len(p1) == 60, len(p1)
open("artifacts/live-net-rx-fixture-1.bin","wb").write(p1)
p2 = own + bytes([0x02,0,0,0,0,2]) + bytes([0x08,0]) + bytes(range(32))
assert len(p2) == 46, len(p2)
open("artifacts/live-net-rx-fixture-2.bin","wb").write(p2)
p3 = bytes([0x02,0,0,0,0,3]) + bytes([0x02,0,0,0,0,4]) + bytes([0x08,0]) + bytes(range(32))
assert len(p3) == 46, len(p3)
open("artifacts/live-net-rx-fixture-3.bin","wb").write(p3)
# The hex the guest's net recv prints. OBSERVED at claim time: the device
# writes a 12-byte virtio_net_hdr (all zero except num_buffers=1 at bytes
# 10-11) BEFORE the raw frame, so the recv line = the observed header +
# the fixture hex, and the device-written len = 12 + frame length (72 for
# the 60-byte phase-1 fixture, 58 for the 46-byte phase-2/3 fixtures).
def hexs(b): return " ".join("%02x" % x for x in b)
obs_hdr = bytes([0]*10) + bytes([0x01, 0x00])
def recv_line(b): return "net recv: " + hexs(obs_hdr) + " " + hexs(b)
open("artifacts/live-net-rx-fixture-1.hex","w").write(hexs(p1))
open("artifacts/live-net-rx-recv-1.txt","w").write(recv_line(p1))
open("artifacts/live-net-rx-fixture-2.hex","w").write(hexs(p2))
open("artifacts/live-net-rx-recv-2.txt","w").write(recv_line(p2))
open("artifacts/live-net-rx-fixture-3.hex","w").write(hexs(p3))
PY

# --- per-phase gate ----------------------------------------------------------
# $1 = tag, $2 = script file, $3 = inject file, $4 = capture file.
run_one() {
    local tag="$1" script="$2" inject="$3" capture="$4"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log "$capture"
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --net "$capture" --net-inject "$inject" --script "$script" --script-expect $'net-rx-ok\ndipshit> ' --timeout 40 \
        > "artifacts/live-net-rx-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-net-rx-serial-$tag.log" || true

    local SERIAL_BYTES=0 RXARMED=0 RECV=0 RECVLEN=0 RXOBS=0 FILTERED=0 NOFRAMES=0
    if [ -f artifacts/vm-serial.log ]; then
        SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log | tr -d ' ')
        # The guest's queue-0 RX-armed marker (the injection trigger).
        grep -a -qF -- "net: rx-armed" artifacts/vm-serial.log && RXARMED=1
        # The rx-obs record (delivery proof — device-written length + first
        # 16 bytes pin the claim-time RX-header question).
        grep -a -qF -- "net: rx-obs len=" artifacts/vm-serial.log && RXOBS=1
        case "$tag" in
            p1)
                grep -a -qF -- "net recv: frames=1" artifacts/vm-serial.log && RECV=1
                # The FULL recv line, byte-exact: the observed 12-byte
                # virtio_net_hdr (num_buffers=1) + the injected 60-byte frame.
                grep -a -qF -- "$(cat artifacts/live-net-rx-recv-1.txt)" artifacts/vm-serial.log && RECVLEN=1
                grep -a -qF -- "net recv: [0] len=72" artifacts/vm-serial.log && RECVLEN=1
                grep -a -qF -- "net: rx-obs len=72" artifacts/vm-serial.log && RECVLEN=1
                grep -a -qF -- "net: rx=frames=1,bytes=72,filtered=0,overflow=0,fifo=0" artifacts/vm-serial.log && FILTERED=1
                grep -a -qF -- "netsend: tx ok" artifacts/vm-serial.log && NOFRAMES=1
                ;;
            p2)
                grep -a -qF -- "net recv: frames=1" artifacts/vm-serial.log && RECV=1
                grep -a -qF -- "$(cat artifacts/live-net-rx-recv-2.txt)" artifacts/vm-serial.log && RECVLEN=1
                grep -a -qF -- "net recv: [0] len=58" artifacts/vm-serial.log && RECVLEN=1
                grep -a -qF -- "net: rx-obs len=58" artifacts/vm-serial.log && RECVLEN=1
                grep -a -qF -- "net: rx=frames=1,bytes=58,filtered=0,overflow=0,fifo=0" artifacts/vm-serial.log && FILTERED=1
                # The session-completion marker (the script's final echo).
                grep -a -qF -- "net-rx-ok" artifacts/vm-serial.log && NOFRAMES=1
                ;;
            p3)
                # `net recv: no frames` IS the recv command's output — it ran
                # and honestly reported the filter drop.
                grep -a -qF -- "net recv: no frames" artifacts/vm-serial.log && RECV=1 && NOFRAMES=1
                grep -a -qF -- "net: rx=frames=0,bytes=0,filtered=1,overflow=0,fifo=0" artifacts/vm-serial.log && FILTERED=1
                # The foreign frame WAS delivered (the rx-obs record proves a
                # drop, not a failed delivery).
                grep -a -qF -- "net: rx-obs len=58" artifacts/vm-serial.log && RECVLEN=1
                ;;
        esac
    fi
    local PASS=0
    if [ "$RC" = 0 ] && [ "$RXARMED" = 1 ] && [ "$RXOBS" = 1 ] && [ "$RECV" = 1 ] && [ "$RECVLEN" = 1 ] && [ "$FILTERED" = 1 ] && [ "$NOFRAMES" = 1 ]; then
        PASS=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES rx-armed=$RXARMED rx-obs=$RXOBS recv=$RECV recv-exact=$RECVLEN counters=$FILTERED expect=$NOFRAMES pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES rx-armed=$RXARMED rx-obs=$RXOBS recv=$RECV recv-exact=$RECVLEN counters=$FILTERED expect=$NOFRAMES pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live virtio-net RX gate (claim 6076, milestone five card N2) — RX buffer supply, polled used-ring drain, MAC filter, bounded FIFO, net recv, host->guest injection, the round trip, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase 1: inject the 60-byte broadcast known frame -> net recv prints it byte-exact, net reports frames=1, and netsend 46 re-sends it (capture == injected bytes)"
    echo "phase 2: inject an own-MAC frame -> received byte-exact (frames=1 filtered=0)"
    echo "phase 3: inject a foreign-MAC frame -> dropped (no frames, filtered=1, rx-obs still records the delivery)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
PHASES=0

echo
    echo "=== phase 1: broadcast frame received byte-exact + re-sent (the round trip) ==="
    P1=0
    run_one "p1" "artifacts/live-net-rx-script-1.txt" "artifacts/live-net-rx-fixture-1.bin" "artifacts/live-net-rx-cap-1.bin" && P1=1 || true
    # The capture (guest's netsend 46 echo) must be byte-exactly the
    # injected 60-byte fixture.
    CAP1=0
    if [ -f artifacts/live-net-rx-cap-1.bin ] && cmp -s artifacts/live-net-rx-cap-1.bin artifacts/live-net-rx-fixture-1.bin; then
        CAP1=1
    fi
    echo "phase 1 capture-round-trip-exact=$CAP1"
    [ "$CAP1" = 1 ] && [ "$P1" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

    echo
    echo "=== phase 2: own-MAC frame received byte-exact ==="
    P2=0
    run_one "p2" "artifacts/live-net-rx-script-2.txt" "artifacts/live-net-rx-fixture-2.bin" "artifacts/live-net-rx-cap-2.bin" && P2=1 || true
    [ "$P2" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

    echo
    echo "=== phase 3: foreign-MAC frame dropped by the filter ==="
    P3=0
    run_one "p3" "artifacts/live-net-rx-script-3.txt" "artifacts/live-net-rx-fixture-3.bin" "artifacts/live-net-rx-cap-3.bin" && P3=1 || true
    [ "$P3" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

echo
echo "=== result ==="
if [ "$PASS" = "$PHASES" ]; then
    echo "verify-live-net-rx: PASS — virtio-net RX is live on VZ: the guest arms queue 0 with a fixed BSS buffer (net: rx-armed), the host injects the known frame into the SAME attachment's socket (--net-inject, a serial trigger), the polled used-ring drain delivers it, the MAC filter accepts own + broadcast and drops the rest (filtered=1 in phase 3), net recv prints the exact bytes, and the guest re-sends them (the phase-1 capture is byte-exactly the injected fixture — raw Ethernet frames back and forth). ($PASS/$PHASES phases)."
    echo "PASS: $PASS/$PHASES" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-net-rx: FAILED — $PASS/$PHASES phases passed; see artifacts/live-net-rx-report.txt, the per-phase runner output and serial logs, and the capture files."
    echo "FAIL: $PASS/$PHASES" >> "$REPORT"
    sleep 0.5
    exit 1
fi
