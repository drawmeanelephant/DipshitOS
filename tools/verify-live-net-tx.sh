#!/usr/bin/env bash
#
# verify-live-net-tx.sh -- claim 1373 (milestone five, card N1) class-B
# gate: the virtio-net TRANSPORT + TX path observed end to end on real VZ
# hardware, byte-exact on the host.
#
# Mechanism: the runner's `--net <capture-file>` flag (OFF by default — the
# default VM is untouched) attaches ONE VZVirtioNetworkDeviceConfiguration
# with a VZFileHandleNetworkDeviceAttachment and a FIXED host MAC
# (02:00:00:00:00:01). The guest's virtio_net.zig transport (modern
# virtio-pci, DID 0x1041 — the 2026-08-11 DID correction) discovers the
# device pre-exit, negotiates features, sets up queue 0 (RX) + queue 1
# (TX), re-arms post-exit, and `netsend` submits a KNOWN Ethernet frame
# through bounded BSS staging; the used ring is drained polled. Every
# guest-transmitted frame lands in the host capture file byte-exactly (the
# device consumes a 12-byte virtio_net_hdr — the claim-1373 observed
# contract — and the RAW Ethernet frame follows).
#
# Phase 1 (single known frame): script `net | netsend 32 | echo`; asserts
#   the net report (did=0x1041 class=0x020000, mac=02:00:00:00:00:01
#   source=feature — the host-set address via the negotiated MAC feature,
#   feat=0x28/0x1 = VER1|MTU|MAC, both queues armed, DRIVER_OK + rearm)
#   and that the capture file is BYTE-EXACTLY the 46-byte fixture:
#   ff*6 (broadcast dst) + 02:00:00:00:00:01 (src) + 08 00 (IPv4
#   ethertype) + payload bytes 00 01 .. 1f (byte i = i & 0xff).
# Phase 2 (ring reuse + honest truncation): script sends 32, then 32
#   again, then 3000 (truncated to the 1500-byte payload bound); asserts
#   three frames in the capture — 46, 46, 1514 bytes — and the tx counter
#   (frames=3). The two 46-byte frames prove one-request-at-a-time ring
#   reuse across submissions; the 1514-byte frame proves bounded staging
#   truncates honestly (the payload is exactly 1500 bytes of i & 0xff).
#
# Honesty: the runner exits 0 only when the expected reply appears; the
# gate additionally asserts every transcript line AND compares the capture
# bytes, so an early exit on the echoed input line cannot pass. Evidence
# under artifacts/: live-net-tx-*.txt (runner output), live-net-tx-*.log
# (serial copies), live-net-tx-*.bin (host captures), and the report.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set DIPSHIT_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# DIPSHIT_KEEP_RUN=1 to keep the scratch dir.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-net-tx.sh
#
# Evidence: artifacts/live-net-tx-gate.txt (full output),
# artifacts/live-net-tx-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-net-tx-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-net-tx-report.txt)"

echo "=== verify-live-net-tx: claim 1373 — virtio-net transport + TX (DID 0x1041, feature negotiation, queue setup, re-arm, byte-exact host capture) ==="

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

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-net-tx
echo "run dir: $RUN_DIR"


# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net
netsend 32
echo net-tx-ok
EOF
cat > "$RUN_DIR/script-2.txt" <<'EOF'
net
netsend 32
netsend 32
netsend 3000
echo net-tx-ok
EOF

# --- byte-exact fixture (the class-A build_known_frame shape) ---------------
RUN_DIR="$RUN_DIR" python3 - <<'PY'
import os
rd = os.environ["RUN_DIR"]
fixture = bytes([0xff]*6) + bytes([0x02,0,0,0,0,1]) + bytes([0x08,0]) + bytes(range(32))
assert len(fixture) == 46, len(fixture)
open(rd+"/live-net-tx-fixture.bin","wb").write(fixture)
# The truncated 3000-byte request: payload clamps at 1500 -> frame 1514.
big = bytes([0xff]*6) + bytes([0x02,0,0,0,0,1]) + bytes([0x08,0]) + bytes(i & 0xff for i in range(1500))
assert len(big) == 1514, len(big)
open(rd+"/live-net-tx-fixture-big.bin","wb").write(big)
PY

# --- per-phase gate ----------------------------------------------------------
# $1 = tag, $2 = script file, $3 = capture file. Returns 0 iff the runner
# saw the expected reply AND the transcript assertions held. The capture
# BYTE comparisons are done per-phase (phase 1 = single fixture frame;
# phase 2 = concatenation of 46 + 46 + 1514).
run_one() {
    local tag="$1" script="$2" capture="$3"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$capture"
    set +e
        # Rot class 1 (#528): the colored prompt killed '<marker>\ndipshit> '
        # anchors; this marker reply is output-only and last.
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --net "$capture" --script "$script" --script-expect "net-tx-ok" --timeout 40 \
        > "$(art live-net-tx-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-net-tx-serial-$tag.log)" || true
    local SER="$(art live-net-tx-serial-$tag.log)"

    local SERIAL_BYTES=0 DID=0 MAC=0 MACSRC=0 FEAT=0 QUEUES=0 STATUS=0 TXREPLY=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" | tr -d ' ')
        # The net report: the OBSERVED device (DID 0x1041, class 0x020000,
        # bus slot), the host-set MAC from the negotiated feature,
        # VER1|MTU|MAC accepted, both queues, DRIVER_OK + re-arm.
        grep -a -qF -- "net: did=0x0000000000001041 class=0x0000000000020000 dev=1" "$SER" && DID=1
        grep -a -qF -- "net: mac=02:00:00:00:00:01 source=feature" "$SER" && MAC=1 && MACSRC=1
        grep -a -qF -- "net: feat=0x0000000000000028/0x0000000000000001" "$SER" && FEAT=1
        grep -a -qF -- "q0=rx:size=4 q1=tx:size=4" "$SER" && QUEUES=1
        grep -a -qF -- "net: status=0x000000000000000f rearm=1" "$SER" && STATUS=1
        # TX replies: every netsend reports the drain (frames/bytes).
        grep -a -qF -- "netsend: tx ok" "$SER" && TXREPLY=1
    fi
    local PASS=0
    if [ "$RC" = 0 ] && [ "$DID" = 1 ] && [ "$MAC" = 1 ] && [ "$MACSRC" = 1 ] && [ "$FEAT" = 1 ] && [ "$QUEUES" = 1 ] && [ "$STATUS" = 1 ] && [ "$TXREPLY" = 1 ]; then
        PASS=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES did=$DID mac=$MAC mac-src=$MACSRC feat=$FEAT queues=$QUEUES status=$STATUS tx-reply=$TXREPLY pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES did=$DID mac=$MAC mac-src=$MACSRC feat=$FEAT queues=$QUEUES status=$STATUS tx-reply=$TXREPLY pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live virtio-net TX gate (claim 1373, milestone five card N1) — transport + TX on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase 1: net + netsend 32 -> host capture must be byte-exactly the 46-byte known frame"
    echo "phase 2: netsend 32 / 32 / 3000 -> ring reuse + honest truncation (46 + 46 + 1514 bytes)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
PHASES=0

echo
    echo "=== phase 1: single known frame (net report + netsend 32) ==="
    P1=0
    run_one "p1" "$RUN_DIR/script-1.txt" "$RUN_DIR/cap-1.bin" && P1=1 || true
    # Phase 1 capture is EXACTLY the 46-byte fixture (one frame).
    CAP1=0
    cp "$RUN_DIR/cap-1.bin" "$(art live-net-tx-cap-1.bin)" 2>/dev/null || true
    if [ -f "$RUN_DIR/cap-1.bin" ] && cmp -s "$RUN_DIR/cap-1.bin" "$RUN_DIR/live-net-tx-fixture.bin"; then
        CAP1=1
    fi
    echo "phase 1 capture-exact-single-frame=$CAP1"
    [ "$CAP1" = 1 ] && [ "$P1" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

    echo
    echo "=== phase 2: ring reuse + honest truncation (32 / 32 / 3000) ==="
    P2=0
    run_one "p2" "$RUN_DIR/script-2.txt" "$RUN_DIR/cap-2.bin" && P2=1 || true
    # Phase 2 capture: 46 + 46 + 1514 = 1606 bytes, laid out exactly as
    # fixture + fixture + big-fixture, and the driver's counter says
    # frames=3 (ring reuse across three submissions).
    CAP2=0
    cp "$RUN_DIR/cap-2.bin" "$(art live-net-tx-cap-2.bin)" 2>/dev/null || true
    if [ -f "$RUN_DIR/cap-2.bin" ] && grep -a -qF -- "netsend: tx ok frames=3" "$(art live-net-tx-serial-p2.log)"; then
        if python3 - "$RUN_DIR" <<'PY'
import sys
rd = sys.argv[1]
cap = open(rd+"/cap-2.bin","rb").read()
f1 = open(rd+"/live-net-tx-fixture.bin","rb").read()
fb = open(rd+"/live-net-tx-fixture-big.bin","rb").read()
raise SystemExit(0 if (len(cap) == 1606 and cap[:46] == f1 and cap[46:92] == f1 and cap[92:] == fb) else 1)
PY
        then
            CAP2=1
        fi
    fi
    echo "phase 2 capture-layout-exact=$CAP2"
    [ "$P2" = 1 ] && [ "$CAP2" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

echo
echo "=== result ==="
if [ "$PASS" = "$PHASES" ]; then
    echo "verify-live-net-tx: PASS — the virtio-net transport is live on VZ: device DID 0x1041 (class 0x020000), VER1|MTU|MAC negotiated (feat=0x28/0x1), host-set MAC read via the feature path (02:00:00:00:00:01), queues 0/1 armed size 4, DRIVER_OK through the post-exit re-arm, and the host capture holds the EXACT Ethernet frames the guest submitted (phase 1: 46-byte known frame byte-for-byte; phase 2: ring reuse + honest truncation — 46 + 46 + 1514 bytes). ($PASS/$PHASES phases)."
    echo "PASS: $PASS/$PHASES" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-net-tx: FAILED — $PASS/$PHASES phases passed; see artifacts/live-net-tx-report.txt, the per-phase runner output and serial logs, and the capture files."
    echo "FAIL: $PASS/$PHASES" >> "$REPORT"
    sleep 0.5
    exit 1
fi
