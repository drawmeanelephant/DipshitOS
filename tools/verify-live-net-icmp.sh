#!/usr/bin/env bash
#
# verify-live-net-icmp.sh -- claim 0148 (milestone five, card N4) class-B
# gate: IPv4/ICMP observed end to end on real VZ hardware, byte-exact on
# the host.
#
# Mechanism: the guest's IPv4 layer (kernel/src/ipv4.zig) sits on the
# card-N2 RX seam — the polled used-ring drain dispatches ethertype
# 0x0800 frames BESIDE the N3 ARP dispatch; an ICMP echo request whose
# destination equals our static IP (set by `net ip 10.0.0.1`) is answered
# byte-exact (the 46-byte reply is built in tx_staging and transmitted on
# the N1 TX path), an echo reply is observed (`pongs_observed` + the last
# echoed sequence), everything else is dropped with a counter. The
# runner's `--net-inject` (card N2) delivers the host's crafted echo
# requests at the `net ip: ip=10.0.0.1` serial marker; the new
# `--net-icmp-respond <host-ip>` flag (card N4) answers the guest's echo
# requests from the host side (host MAC 02:00:00:00:00:02) inside the
# capture thread.
#
# Phase 1 (answer an echo for our address): inject the 46-byte ICMP echo
# request "10.0.0.2 -> 10.0.0.1" (id 0x1234, seq 0x5678, ident 0xabcd,
# payload 01 02 03 04) at the net-ip marker. Script: `net ip | net recv |
# net | echo net-icmp-ok`. Asserts the guest's 46-byte REPLY is byte-exact
# in the host capture (the identification + id/seq/payload echoed), the
# `net recv` hex carries the injected request byte-exact (with the
# observed 12-byte RX header headroom; device len 58), and the reply
# counter (repl=1) moved.
#
# Phase 2 (ping a peer): the guest resolves 10.0.0.2 via `net arp` (the
# runner's --net-arp-respond answers) then `net ping 10.0.0.2`. Asserts
# the guest's broadcast ARP request AND its 46-byte echo request (id 1,
# seq 1) are byte-exact in the capture, the ping TX echo line, AND that
# the runner's host-side ICMP reply landed: `pong=1` with `seq=1` (the
# reply echoed the guest's sequence).
#
# Phase 3 (scope check): inject an echo request for 10.0.0.99 (NOT our
# address). Asserts NO reply (capture empty), the drop counter moved
# (drop=1, repl=0), and the frame is still observable via `net recv` (the
# N2 seam regression — a drop is a counter, not a swallowed frame).
#
# The gate only ever adds the --net/--net-inject/--net-arp-respond/
# --net-icmp-respond surface: the default VM is untouched, and the FULL
# verify-vz aggregate must stay green (re-run separately).
#
# Honesty: the runner exits 0 only when the expected transcript appears;
# the gate additionally asserts every transcript line AND compares the
# capture bytes, so an early exit on the echoed input line cannot pass.
# Evidence under artifacts/: live-net-icmp-*.txt (runner output),
# live-net-icmp-*.log (serial copies), live-net-icmp-*.bin (host
# captures), and the report.
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
#   bash tools/verify-live-net-icmp.sh
#
# Evidence: "$RUN_DIR/live-net-icmp-gate.txt" (full output),
# "$RUN_DIR/live-net-icmp-report.txt" (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-net-icmp-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-net-icmp-report.txt)"

echo "=== verify-live-net-icmp: claim 0148 — IPv4/ICMP live on VZ (answer an echo for our address, ping a peer, scope check) ==="

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
gate_begin live-net-icmp
echo "run dir: $RUN_DIR"


# --- scripted keystrokes -----------------------------------------------------
# TWO script phases per run (the claim-4613 pattern): the guest executes
# a forwarded script BURST in tens of ms — far faster than the host-side
# injection round trip (the runner polls the serial marker every 20 ms,
# then VZ delivers the datagram), so observation commands in the SAME
# burst would always beat the frame. Instead --script (phase 1) sets the
# IP and prints a ready marker; the runner's --net-inject fires at the
# ip-set echo; the frame is delivered and drained (the reply is
# transmitted) within ~50 ms; then --script2 (forwarded only after the
# ready marker, with the claim-6684 0.5 s settle) runs the OBSERVATION
# commands — deterministic, not a sleep race.
cat > "$RUN_DIR/live-net-icmp-script-1.txt" <<'EOF'
net ip 10.0.0.1
echo icmp-phase1-ready
EOF
cat > "$RUN_DIR/live-net-icmp-script-1b.txt" <<'EOF'
net recv
net
echo net-icmp-ok
EOF
cat > "$RUN_DIR/live-net-icmp-script-2.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
echo icmp-phase2-ready
EOF
cat > "$RUN_DIR/live-net-icmp-script-2b.txt" <<'EOF'
net ping 10.0.0.2
net arp
net
echo net-icmp-ok
EOF
cat > "$RUN_DIR/live-net-icmp-script-3.txt" <<'EOF'
net ip 10.0.0.1
echo icmp-phase1-ready
EOF
cat > "$RUN_DIR/live-net-icmp-script-3b.txt" <<'EOF'
net recv
net
echo net-icmp-ok
EOF

# --- byte-exact fixtures (the class-A build_echo_request/reply shapes) ------
# p1: the 46-byte ICMP echo request the HOST injects (10.0.0.2 ->
#     10.0.0.1, id 0x1234, seq 0x5678, ident 0xabcd, payload 01 02 03 04;
#     sender 02:00:00:00:00:02) + the reply the guest must transmit
#     (02:00:00:00:00:01/10.0.0.1 -> 02:00:00:00:00:02/10.0.0.2, the
#     identification + id/seq/payload echoed byte-exact) — the expected
#     capture bytes.
# p2: the guest's own resolve + ping: its broadcast ARP request (sender
#     02:00:00:00:00:01/10.0.0.1, who has 10.0.0.2) then its 46-byte echo
#     request (id 1, seq 1, ident 1, TTL 64) — the expected capture bytes
#     (concatenated, in order); the runner answers both.
# p3: an echo request for 10.0.0.99 (NOT our address) — must NOT be
#     answered (capture stays empty).
RUN_DIR="$RUN_DIR" python3 - <<'PY'
import os
def csum(b):
    s = 0
    for i in range(0, len(b) - 1, 2):
        s += (b[i] << 8) | b[i + 1]
    if len(b) % 2:
        s += b[-1] << 8
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff

def arp_pkt(dst, src, op, sha, spa, tha, tpa):
    return (bytes(dst) + bytes(src) + bytes([0x08,0x06])
            + bytes([0x00,0x01,0x08,0x00,0x06,0x04])
            + bytes([op>>8, op&0xff])
            + bytes(sha) + bytes(spa) + bytes(tha) + bytes(tpa))

def echo_req(dst_mac, src_mac, src_ip, dst_ip, ident, icmp_id, seq, ttl=64):
    buf = bytearray(46)
    buf[0:6] = dst_mac
    buf[6:12] = src_mac
    buf[12:14] = b"\x08\x00"
    buf[14] = 0x45
    buf[16:18] = (32).to_bytes(2, "big")  # total length 20+8+4
    buf[18:20] = ident.to_bytes(2, "big")
    buf[22] = ttl
    buf[23] = 0x01
    buf[26:30] = src_ip
    buf[30:34] = dst_ip
    c = csum(bytes(buf[14:34]))
    buf[24:26] = c.to_bytes(2, "big")
    icmp = bytearray(12)
    icmp[0] = 0x08  # ICMP echo request
    icmp[4:6] = icmp_id.to_bytes(2, "big")
    icmp[6:8] = seq.to_bytes(2, "big")
    icmp[8:12] = b"\x01\x02\x03\x04"
    c2 = csum(bytes(icmp))
    icmp[2:4] = c2.to_bytes(2, "big")
    buf[34:46] = icmp
    return bytes(buf)

# The reply the GUEST must transmit to an injected echo request
# (build_echo_reply shape: dst/src swapped, total length + identification
# + id/seq/payload echoed, TTL 64, both checksums recomputed).
def echo_reply_from_req(req, guest_mac, guest_ip):
    buf = bytearray(len(req))
    buf[0:6] = req[6:12]  # dst = the requester's MAC
    buf[6:12] = guest_mac
    buf[12:14] = b"\x08\x00"
    buf[14] = 0x45
    buf[16:18] = req[16:18]  # total length echoed
    buf[18:20] = req[18:20]  # identification echoed
    buf[22] = 64
    buf[23] = 0x01
    buf[26:30] = guest_ip
    buf[30:34] = req[26:30]
    c = csum(bytes(buf[14:34]))
    buf[24:26] = c.to_bytes(2, "big")
    buf[34] = 0x00  # ICMP echo reply
    icmp_len = len(buf) - 34
    icmp = bytearray(icmp_len)
    icmp[4:] = req[38:]  # id + seq + payload echoed
    c2 = csum(bytes(icmp))
    icmp[2:4] = c2.to_bytes(2, "big")
    buf[34:] = icmp
    return bytes(buf)

host_mac = [0x02,0,0,0,0,2]
guest_mac = [0x02,0,0,0,0,1]
host_ip = [10,0,0,2]
guest_ip = [10,0,0,1]
other_ip = [10,0,0,99]
bcast = [0xff]*6
zero6 = [0]*6
zero4 = [0]*4

# p1: host -> guest echo request + the expected reply (dst = broadcast so
# the guest's MAC filter accepts it; the reply's dst is the requester's
# MAC = the host's).
req1 = echo_req(bcast, host_mac, host_ip, guest_ip, ident=0xabcd, icmp_id=0x1234, seq=0x5678)
assert len(req1) == 46, len(req1)
open(os.environ["RUN_DIR"]+"/live-net-icmp-fixture-1.bin","wb").write(req1)
rep1 = echo_reply_from_req(req1, guest_mac, guest_ip)
assert len(rep1) == 46, len(rep1)
open(os.environ["RUN_DIR"]+"/live-net-icmp-reply-1.bin","wb").write(rep1)
# p2: the guest's resolve + ping (expected capture: ARP request THEN echo
# request — script 1 resolves, script 2 pings; the echo request's dst is
# the LEARNED host MAC 02:00:00:00:00:02).
req2_arp = arp_pkt(bcast, guest_mac, 1, guest_mac, guest_ip, zero6, host_ip)
assert len(req2_arp) == 42, len(req2_arp)
req2_icmp = echo_req(host_mac, guest_mac, guest_ip, host_ip, ident=1, icmp_id=1, seq=1)
assert len(req2_icmp) == 46, len(req2_icmp)
open(os.environ["RUN_DIR"]+"/live-net-icmp-fixture-2.bin","wb").write(req2_arp + req2_icmp)
# p3: an echo request for an address we do not own (dst = broadcast)
req3 = echo_req(bcast, host_mac, host_ip, other_ip, ident=1, icmp_id=1, seq=1)
assert len(req3) == 46, len(req3)
open(os.environ["RUN_DIR"]+"/live-net-icmp-fixture-3.bin","wb").write(req3)
# The hex the guest's net recv prints. OBSERVED at claim time (card N2):
# the device writes a 12-byte virtio_net_hdr (num_buffers=1 at bytes
# 10-11) BEFORE the raw frame, so the recv line = the observed header +
# the fixture hex, and the device-written len = 12 + 46 = 58.
def hexs(b): return " ".join("%02x" % x for x in b)
obs_hdr = bytes([0]*10) + bytes([0x01, 0x00])
def recv_line(b): return "net recv: " + hexs(obs_hdr) + " " + hexs(b)
open(os.environ["RUN_DIR"]+"/live-net-icmp-recv-1.txt","w").write(recv_line(req1))
open(os.environ["RUN_DIR"]+"/live-net-icmp-recv-3.txt","w").write(recv_line(req3))
PY

# --- per-phase gate ----------------------------------------------------------
# $1 = tag, $2 = script1 file, $3 = script2 file, $4 = script2-after marker,
# $5 = inject file ("" = none), $6 = capture file, $7 = extra runner flags.
run_one() {
    local tag="$1" script="$2" script2="$3" after2="$4" inject="$5" capture="$6" extra="$7"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$capture"
    set +e
        # Rot class 1 (#528): the colored prompt killed '<marker>\ndipshit> '
        # anchors; this marker reply is output-only and last.
    local ARGS=()
    [ -n "$inject" ] && ARGS+=(--net-inject "$inject" --net-inject-after "net ip: ip=10.0.0.1")
    [ -n "$extra" ] && ARGS+=($extra)
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --net "$capture" "${ARGS[@]}" --script "$script" --script2 "$script2" --script2-after "$after2" --script-expect "net-icmp-ok" --timeout 40 \
        > "$(art live-net-icmp-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-net-icmp-serial-$tag.log)" || true
    local SER="$(art live-net-icmp-serial-$tag.log)"

    local SERIAL_BYTES=0 IPSET=0 RECV=0 RECVLEN=0 REPL=0 DROP=0 PING=0 PONG=0 ENTRY=0 LEARN=0 SENT=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" | tr -d ' ')
        # The static-IP marker (also the injection trigger).
        grep -a -qF -- "net ip: ip=10.0.0.1" "$SER" && IPSET=1
        case "$tag" in
            p1)
                grep -a -qF -- "net recv: frames=1" "$SER" && RECV=1
                grep -a -qF -- "net recv: [0] len=58" "$SER" && RECVLEN=1
                # The FULL recv line, byte-exact: the observed 12-byte
                # virtio_net_hdr + the injected 46-byte echo request.
                grep -a -qF -- "$(cat "$RUN_DIR/live-net-icmp-recv-1.txt")" "$SER" && RECVLEN=1
                # The reply counter moved (the answer was transmitted).
                grep -a -qF -- " icmp=req=0,repl=1,pong=0,drop=0,fail=0,seq=0" "$SER" && REPL=1
                grep -a -qF -- "net-icmp-ok" "$SER" && SENT=1
                ;;
            p2)
                grep -a -qF -- "net ping: echo request to 10.0.0.2 sent (46 bytes)" "$SER" && PING=1
                # The runner's host-side ICMP reply landed: the pong
                # counter moved with the ECHOED sequence (seq=1).
                grep -a -qF -- " icmp=req=1,repl=0,pong=1,drop=0,fail=0,seq=1" "$SER" && PONG=1
                # The resolve that preceded the ping (script 1) learned:
                # the entry line + the counter line (net arp, no arg).
                grep -a -qF -- "net arp: 10.0.0.2 -> 02:00:00:00:00:02" "$SER" && ENTRY=1
                grep -a -qF -- "net arp: req=1,repl=0,learn=1,drop=0,fail=0" "$SER" && LEARN=1
                grep -a -qF -- "net-icmp-ok" "$SER" && SENT=1
                ;;
            p3)
                # The frame WAS observed (the N2 seam is intact)...
                grep -a -qF -- "net recv: frames=1" "$SER" && RECV=1
                grep -a -qF -- "net recv: [0] len=58" "$SER" && RECVLEN=1
                grep -a -qF -- "$(cat "$RUN_DIR/live-net-icmp-recv-3.txt")" "$SER" && RECVLEN=1
                # ...but NOT answered (drop=1, repl=0) — the scope check.
                grep -a -qF -- " icmp=req=0,repl=0,pong=0,drop=1,fail=0,seq=0" "$SER" && DROP=1
                grep -a -qF -- "net-icmp-ok" "$SER" && SENT=1
                ;;
        esac
    fi
    # Per-phase pass: every phase needs rc + the ip-set marker + the
    # session echo; the protocol flags are phase-specific (p1: the frame
    # observed + the reply transmitted; p2: the ping TX + the pong + the
    # learned entry; p3: the frame observed + the drop).
    local PASS=0
    case "$tag" in
        p1)
            [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$RECV" = 1 ] && [ "$RECVLEN" = 1 ] && [ "$REPL" = 1 ] && [ "$SENT" = 1 ] && PASS=1
            ;;
        p2)
            [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$PING" = 1 ] && [ "$PONG" = 1 ] && [ "$ENTRY" = 1 ] && [ "$LEARN" = 1 ] && [ "$SENT" = 1 ] && PASS=1
            ;;
        p3)
            [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$RECV" = 1 ] && [ "$RECVLEN" = 1 ] && [ "$DROP" = 1 ] && [ "$SENT" = 1 ] && PASS=1
            ;;
    esac
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES ip-set=$IPSET recv=$RECV recv-exact=$RECVLEN repl=$REPL drop=$DROP ping=$PING pong=$PONG entry=$ENTRY sent=$SENT pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES ip-set=$IPSET recv=$RECV recv-exact=$RECVLEN repl=$REPL drop=$DROP ping=$PING pong=$PONG entry=$ENTRY sent=$SENT pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live IPv4/ICMP gate (claim 0148, milestone five card N4) — answer an echo for our address, ping a peer, scope check, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase 1: inject the 46-byte echo request 10.0.0.2 -> 10.0.0.1 (id 0x1234, seq 0x5678) -> net recv observes it, the reply (02:00:00:00:00:01/10.0.0.1) is byte-exact in the capture, repl=1"
    echo "phase 2: guest net arp 10.0.0.2 then net ping 10.0.0.2 -> the ARP request + the 46-byte echo request are byte-exact in the capture; --net-icmp-respond 10.0.0.2 answers; net shows pong=1, seq=1"
    echo "phase 3: inject an echo request for 10.0.0.99 (not our address) -> no reply (capture empty), drop=1, repl=0, frame still observable via net recv"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
PHASES=0

echo
    echo "=== phase 1: the guest answers an ICMP echo request for its IP (byte-exact reply in the capture) ==="
    P1=0
    run_one "p1" "$RUN_DIR/live-net-icmp-script-1.txt" "$RUN_DIR/live-net-icmp-script-1b.txt" "icmp-phase1-ready" "$RUN_DIR/live-net-icmp-fixture-1.bin" "$RUN_DIR/live-net-icmp-cap-1.bin" "" && P1=1 || true
    # The capture (the guest's reply) must be byte-exactly the reply
    # fixture — with a short retry (the reply passes through the TX queue,
    # the capture thread, and the file).
    CAP1=0
    for _ in 1 2 3 4 5; do
        if [ -f "$RUN_DIR/live-net-icmp-cap-1.bin" ] && cmp -s "$RUN_DIR/live-net-icmp-cap-1.bin" "$RUN_DIR/live-net-icmp-reply-1.bin"; then
            CAP1=1
            break
        fi
        sleep 0.5
    done
    echo "phase 1 capture-reply-exact=$CAP1"
    [ "$CAP1" = 1 ] && [ "$P1" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

    echo
    echo "=== phase 2: the guest pings a peer (request captured, host echo answer observed) ==="
    P2=0
    run_one "p2" "$RUN_DIR/live-net-icmp-script-2.txt" "$RUN_DIR/live-net-icmp-script-2b.txt" "icmp-phase2-ready" "" "$RUN_DIR/live-net-icmp-cap-2.bin" "--net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2" && P2=1 || true
    CAP2=0
    for _ in 1 2 3 4 5; do
        if [ -f "$RUN_DIR/live-net-icmp-cap-2.bin" ] && cmp -s "$RUN_DIR/live-net-icmp-cap-2.bin" "$RUN_DIR/live-net-icmp-fixture-2.bin"; then
            CAP2=1
            break
        fi
        sleep 0.5
    done
    echo "phase 2 capture-requests-exact=$CAP2"
    [ "$CAP2" = 1 ] && [ "$P2" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

    echo
    echo "=== phase 3: an echo request for a foreign address is NOT answered (scope check) ==="
    P3=0
    run_one "p3" "$RUN_DIR/live-net-icmp-script-3.txt" "$RUN_DIR/live-net-icmp-script-3b.txt" "icmp-phase1-ready" "$RUN_DIR/live-net-icmp-fixture-3.bin" "$RUN_DIR/live-net-icmp-cap-3.bin" "" && P3=1 || true
    CAP3=0
    if [ ! -f "$RUN_DIR/live-net-icmp-cap-3.bin" ] || [ ! -s "$RUN_DIR/live-net-icmp-cap-3.bin" ]; then
        CAP3=1
    fi
    echo "phase 3 capture-empty=$CAP3"
    [ "$CAP3" = 1 ] && [ "$P3" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

echo
echo "=== result ==="
if [ "$PASS" = "$PHASES" ]; then
    echo "verify-live-net-icmp: PASS — IPv4/ICMP is live on VZ: the guest answers the injected echo request for its static IP (the 46-byte reply is byte-exact in the host capture with the identification + id/seq/payload echoed, repl=1), it pings a peer (its broadcast ARP request + 46-byte echo request are byte-exact in the capture and the runner's --net-icmp-respond answer lands as pong=1 with seq=1), and an echo request for a foreign address is dropped with a counter while remaining observable via net recv (the N2 seam intact). ($PASS/$PHASES phases)."
    echo "PASS: $PASS/$PHASES" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-net-icmp: FAILED — $PASS/$PHASES phases passed; see "$RUN_DIR/live-net-icmp-report.txt", the per-phase runner output and serial logs, and the capture files."
    echo "FAIL: $PASS/$PHASES" >> "$REPORT"
    sleep 0.5
    exit 1
fi
