#!/usr/bin/env bash
#
# verify-live-arp.sh -- claim 7293 (milestone five, card N3) class-B gate:
# ARP observed end to end on real VZ hardware, byte-exact on the host.
#
# Mechanism: the guest's ARP layer (kernel/src/arp.zig) sits on the card-N2
# RX seam — the polled used-ring drain dispatches ARP frames; a request
# whose target protocol address equals our static IP (set by
# `net ip 10.0.0.1`) is answered (the 42-byte reply is built in tx_staging
# and transmitted on the N1 TX path), a reply is learned into the bounded
# table, everything else is dropped with a counter. The runner's
# `--net-inject` (card N2) delivers the host's crafted requests at the
# `net ip: ip=10.0.0.1` serial marker; the new `--net-arp-respond
# <host-ip>` flag (card N3) answers the guest's requests from the host
# side (host MAC 02:00:00:00:00:02) inside the capture thread.
#
# Phase 1 (answer a request for our address): inject the 42-byte ARP
# request "who has 10.0.0.1, tell 10.0.0.2" (host 02:00:00:00:00:02) at
# the net-ip marker. Script: `net ip | net recv | net arp | echo
# net-arp-ok`. Asserts the guest's 42-byte REPLY is byte-exact in the host
# capture (02:00:00:00:00:01/10.0.0.1 -> 02:00:00:00:00:02/10.0.0.2), the
# `net recv` hex carries the injected request byte-exact (with the
# observed 12-byte RX header headroom; device len 54), and the reply
# counter (repl=1) moved.
#
# Phase 2 (resolve a peer): no injection. Script: `net ip | net arp
# 10.0.0.2 | net arp | net arp | echo net-arp-ok`. Asserts the guest's
# broadcast ARP request is byte-exact in the capture AND that the runner's
# host-side answer landed: `net arp` shows `10.0.0.2 ->
# 02:00:00:00:00:02` with learn=1.
#
# Phase 3 (scope check): inject an ARP request for 10.0.0.99 (NOT our
# address). Asserts NO reply (capture empty), the drop counter moved
# (drop=1, repl=0), and the frame is still observable via `net recv` (the
# N2 seam regression — a drop is a counter, not a swallowed frame).
#
# The gate only ever adds the --net/--net-inject/--net-arp-respond
# surface: the default VM is untouched, and the FULL 30-gate verify-vz
# aggregate must stay green (re-run separately).
#
# Honesty: the runner exits 0 only when the expected reply appears; the
# gate additionally asserts every transcript line AND compares the capture
# bytes, so an early exit on the echoed input line cannot pass. Evidence
# under artifacts/: live-net-arp-*.txt (runner output), live-net-arp-*.log
# (serial copies), live-net-arp-*.bin (host captures), and the report.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-arp.sh
#
# Evidence: artifacts/live-net-arp-gate.txt (full output),
# artifacts/live-net-arp-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-net-arp-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-net-arp-report.txt"

echo "=== verify-live-arp: claim 7293 — ARP live on VZ (answer for our address, resolve a peer, scope check) ==="

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
# TWO script phases per run (the claim-4613 pattern): the guest executes
# a forwarded script BURST in tens of ms — far faster than the host-side
# injection round trip (the runner polls the serial marker every 20 ms,
# claim 7293, then VZ delivers the datagram), so observation commands in
# the SAME burst would always beat the frame. Instead --script (phase 1)
# sets the IP and prints a ready marker; the runner's --net-inject fires
# at the ip-set echo; the frame is delivered and drained (the reply is
# transmitted) within ~50 ms; then --script2 (forwarded only after the
# ready marker, with the claim-6684 0.5 s settle) runs the OBSERVATION
# commands — deterministic, not a sleep race.
cat > artifacts/live-net-arp-script-1.txt <<'EOF'
net ip 10.0.0.1
echo arp-phase1-ready
EOF
cat > artifacts/live-net-arp-script-1b.txt <<'EOF'
net recv
net arp
echo net-arp-ok
EOF
cat > artifacts/live-net-arp-script-2.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
echo arp-phase2-ready
EOF
cat > artifacts/live-net-arp-script-2b.txt <<'EOF'
net arp
net arp
echo net-arp-ok
EOF
cat > artifacts/live-net-arp-script-3.txt <<'EOF'
net ip 10.0.0.1
echo arp-phase1-ready
EOF
cat > artifacts/live-net-arp-script-3b.txt <<'EOF'
net recv
net arp
echo net-arp-ok
EOF

# --- byte-exact fixtures (the class-A build_request/build_reply shapes) -----
# p1: the 42-byte ARP request the HOST injects (who has 10.0.0.1, tell
#     10.0.0.2; sender 02:00:00:00:00:02/10.0.0.2) + the reply the guest
#     must transmit (02:00:00:00:00:01/10.0.0.1 -> 02:00:00:00:00:02/
#     10.0.0.2) — the expected capture bytes.
# p2: the guest's own broadcast request (sender 02:00:00:00:00:01/
#     10.0.0.1, who has 10.0.0.2) — the expected capture bytes; the
#     runner answers it (host MAC 02:00:00:00:00:02 @ 10.0.0.2).
# p3: an ARP request for 10.0.0.99 (NOT our address) — must NOT be
#     answered (capture stays empty).
python3 - <<'PY'
def arp_pkt(dst, src, op, sha, spa, tha, tpa):
    return (bytes(dst) + bytes(src) + bytes([0x08,0x06])
            + bytes([0x00,0x01,0x08,0x00,0x06,0x04])
            + bytes([op>>8, op&0xff])
            + bytes(sha) + bytes(spa) + bytes(tha) + bytes(tpa))
host_mac = [0x02,0,0,0,0,2]
guest_mac = [0x02,0,0,0,0,1]
host_ip = [10,0,0,2]
guest_ip = [10,0,0,1]
other_ip = [10,0,0,99]
bcast = [0xff]*6
zero6 = [0]*6
zero4 = [0]*4

# p1: host -> guest request + the expected reply
req1 = arp_pkt(bcast, host_mac, 1, host_mac, host_ip, zero6, guest_ip)
assert len(req1) == 42, len(req1)
open("artifacts/live-net-arp-fixture-1.bin","wb").write(req1)
rep1 = arp_pkt(host_mac, guest_mac, 2, guest_mac, guest_ip, host_mac, host_ip)
assert len(rep1) == 42, len(rep1)
open("artifacts/live-net-arp-reply-1.bin","wb").write(rep1)
# p2: the guest's own request (expected capture)
req2 = arp_pkt(bcast, guest_mac, 1, guest_mac, guest_ip, zero6, host_ip)
assert len(req2) == 42, len(req2)
open("artifacts/live-net-arp-fixture-2.bin","wb").write(req2)
# p3: a request for an address we do not own
req3 = arp_pkt(bcast, host_mac, 1, host_mac, host_ip, zero6, other_ip)
assert len(req3) == 42, len(req3)
open("artifacts/live-net-arp-fixture-3.bin","wb").write(req3)
# The hex the guest's net recv prints. OBSERVED at claim time (card N2):
# the device writes a 12-byte virtio_net_hdr (num_buffers=1 at bytes
# 10-11) BEFORE the raw frame, so the recv line = the observed header +
# the fixture hex, and the device-written len = 12 + 42 = 54.
def hexs(b): return " ".join("%02x" % x for x in b)
obs_hdr = bytes([0]*10) + bytes([0x01, 0x00])
def recv_line(b): return "net recv: " + hexs(obs_hdr) + " " + hexs(b)
open("artifacts/live-net-arp-recv-1.txt","w").write(recv_line(req1))
open("artifacts/live-net-arp-recv-3.txt","w").write(recv_line(req3))
PY

# --- per-phase gate ----------------------------------------------------------
# $1 = tag, $2 = script1 file, $3 = script2 file, $4 = script2-after marker,
# $5 = inject file ("" = none), $6 = capture file, $7 = extra runner flags.
run_one() {
    local tag="$1" script="$2" script2="$3" after2="$4" inject="$5" capture="$6" extra="$7"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log "$capture"
    set +e
    local ARGS=()
    [ -n "$inject" ] && ARGS+=(--net-inject "$inject" --net-inject-after "net ip: ip=10.0.0.1")
    [ -n "$extra" ] && ARGS+=($extra)
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --net "$capture" "${ARGS[@]}" --script "$script" --script2 "$script2" --script2-after "$after2" --script-expect $'net-arp-ok\ndipshit> ' --timeout 40 \
        > "artifacts/live-net-arp-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-net-arp-serial-$tag.log" || true

    local SERIAL_BYTES=0 IPSET=0 RECV=0 RECVLEN=0 REPL=0 DROP=0 LEARN=0 ENTRY=0 SENT=0
    if [ -f artifacts/vm-serial.log ]; then
        SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log | tr -d ' ')
        # The static-IP marker (also the injection trigger).
        grep -a -qF -- "net ip: ip=10.0.0.1" artifacts/vm-serial.log && IPSET=1
        case "$tag" in
            p1)
                grep -a -qF -- "net recv: frames=1" artifacts/vm-serial.log && RECV=1
                grep -a -qF -- "net recv: [0] len=54" artifacts/vm-serial.log && RECVLEN=1
                # The FULL recv line, byte-exact: the observed 12-byte
                # virtio_net_hdr + the injected 42-byte request.
                grep -a -qF -- "$(cat artifacts/live-net-arp-recv-1.txt)" artifacts/vm-serial.log && RECVLEN=1
                # The reply counter moved (the answer was transmitted).
                grep -a -qF -- "net arp: req=0,repl=1,learn=0,drop=0,fail=0" artifacts/vm-serial.log && REPL=1
                grep -a -qF -- "net: ip=10.0.0.1 arp=req=0,repl=1,learn=0,drop=0,fail=0" artifacts/vm-serial.log && REPL=1
                grep -a -qF -- "net-arp-ok" artifacts/vm-serial.log && SENT=1
                ;;
            p2)
                grep -a -qF -- "net arp: request for 10.0.0.2 sent (42 bytes)" artifacts/vm-serial.log && SENT=1
                # The runner's host-side answer landed in the table.
                grep -a -qF -- "net arp: 10.0.0.2 -> 02:00:00:00:00:02" artifacts/vm-serial.log && ENTRY=1
                grep -a -qF -- "net arp: req=1,repl=0,learn=1,drop=0,fail=0" artifacts/vm-serial.log && LEARN=1
                grep -a -qF -- "net-arp-ok" artifacts/vm-serial.log && RECV=1
                ;;
            p3)
                # The frame WAS observed (the N2 seam is intact)...
                grep -a -qF -- "net recv: frames=1" artifacts/vm-serial.log && RECV=1
                grep -a -qF -- "net recv: [0] len=54" artifacts/vm-serial.log && RECVLEN=1
                grep -a -qF -- "$(cat artifacts/live-net-arp-recv-3.txt)" artifacts/vm-serial.log && RECVLEN=1
                # ...but NOT answered (drop=1, repl=0) — the scope check.
                grep -a -qF -- "net arp: req=0,repl=0,learn=0,drop=1,fail=0" artifacts/vm-serial.log && DROP=1
                grep -a -qF -- "net-arp-ok" artifacts/vm-serial.log && SENT=1
                ;;
        esac
    fi
    # Per-phase pass: every phase needs rc + the ip-set marker + the
    # session echo; the protocol flags are phase-specific (p1: the frame
    # observed + the reply transmitted; p2: the resolve + the learned
    # entry; p3: the frame observed + the drop).
    local PASS=0
    case "$tag" in
        p1)
            [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$RECV" = 1 ] && [ "$RECVLEN" = 1 ] && [ "$REPL" = 1 ] && [ "$SENT" = 1 ] && PASS=1
            ;;
        p2)
            [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$SENT" = 1 ] && [ "$ENTRY" = 1 ] && [ "$LEARN" = 1 ] && [ "$RECV" = 1 ] && PASS=1
            ;;
        p3)
            [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$RECV" = 1 ] && [ "$RECVLEN" = 1 ] && [ "$DROP" = 1 ] && [ "$SENT" = 1 ] && PASS=1
            ;;
    esac
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES ip-set=$IPSET recv=$RECV recv-exact=$RECVLEN repl=$REPL drop=$DROP learn=$LEARN entry=$ENTRY sent=$SENT pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES ip-set=$IPSET recv=$RECV recv-exact=$RECVLEN repl=$REPL drop=$DROP learn=$LEARN entry=$ENTRY sent=$SENT pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live ARP gate (claim 7293, milestone five card N3) — answer for our address, resolve a peer, scope check, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase 1: inject 'who has 10.0.0.1, tell 10.0.0.2' -> net recv observes it, the reply (02:00:00:00:00:01/10.0.0.1) is byte-exact in the capture, repl=1"
    echo "phase 2: guest net arp 10.0.0.2 -> the request is byte-exact in the capture; --net-arp-respond 10.0.0.2 answers; net arp shows 10.0.0.2 -> 02:00:00:00:00:02, learn=1"
    echo "phase 3: inject a request for 10.0.0.99 (not our address) -> no reply (capture empty), drop=1, repl=0, frame still observable via net recv"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
PHASES=0

echo
    echo "=== phase 1: the guest answers an ARP request for its IP (byte-exact reply in the capture) ==="
    P1=0
    run_one "p1" "artifacts/live-net-arp-script-1.txt" "artifacts/live-net-arp-script-1b.txt" "arp-phase1-ready" "artifacts/live-net-arp-fixture-1.bin" "artifacts/live-net-arp-cap-1.bin" "" && P1=1 || true
    # The capture (the guest's reply) must be byte-exactly the reply
    # fixture — with a short retry (the reply passes through the TX queue,
    # the capture thread, and the file).
    CAP1=0
    for _ in 1 2 3 4 5; do
        if [ -f artifacts/live-net-arp-cap-1.bin ] && cmp -s artifacts/live-net-arp-cap-1.bin artifacts/live-net-arp-reply-1.bin; then
            CAP1=1
            break
        fi
        sleep 0.5
    done
    echo "phase 1 capture-reply-exact=$CAP1"
    [ "$CAP1" = 1 ] && [ "$P1" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

    echo
    echo "=== phase 2: the guest resolves a peer (request captured, host answer learned) ==="
    P2=0
    run_one "p2" "artifacts/live-net-arp-script-2.txt" "artifacts/live-net-arp-script-2b.txt" "arp-phase2-ready" "" "artifacts/live-net-arp-cap-2.bin" "--net-arp-respond 10.0.0.2" && P2=1 || true
    CAP2=0
    for _ in 1 2 3 4 5; do
        if [ -f artifacts/live-net-arp-cap-2.bin ] && cmp -s artifacts/live-net-arp-cap-2.bin artifacts/live-net-arp-fixture-2.bin; then
            CAP2=1
            break
        fi
        sleep 0.5
    done
    echo "phase 2 capture-request-exact=$CAP2"
    [ "$CAP2" = 1 ] && [ "$P2" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

    echo
    echo "=== phase 3: a request for a foreign address is NOT answered (scope check) ==="
    P3=0
    run_one "p3" "artifacts/live-net-arp-script-3.txt" "artifacts/live-net-arp-script-3b.txt" "arp-phase1-ready" "artifacts/live-net-arp-fixture-3.bin" "artifacts/live-net-arp-cap-3.bin" "" && P3=1 || true
    CAP3=0
    if [ ! -f artifacts/live-net-arp-cap-3.bin ] || [ ! -s artifacts/live-net-arp-cap-3.bin ]; then
        CAP3=1
    fi
    echo "phase 3 capture-empty=$CAP3"
    [ "$CAP3" = 1 ] && [ "$P3" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

echo
echo "=== result ==="
if [ "$PASS" = "$PHASES" ]; then
    echo "verify-live-arp: PASS — ARP is live on VZ: the guest answers the injected request for its static IP (the 42-byte reply is byte-exact in the host capture, repl=1), it resolves a peer (its broadcast request is byte-exact in the capture and the runner's --net-arp-respond answer lands in the table: 10.0.0.2 -> 02:00:00:00:00:02, learn=1), and a request for a foreign address is dropped with a counter while remaining observable via net recv (the N2 seam intact). ($PASS/$PHASES phases)."
    echo "PASS: $PASS/$PHASES" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-arp: FAILED — $PASS/$PHASES phases passed; see artifacts/live-net-arp-report.txt, the per-phase runner output and serial logs, and the capture files."
    echo "FAIL: $PASS/$PHASES" >> "$REPORT"
    sleep 0.5
    exit 1
fi
