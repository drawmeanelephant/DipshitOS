#!/usr/bin/env bash
#
# verify-live-net-udp.sh -- claim 8552 (milestone five, card N5) class-B
# gate: UDP observed end to end on real VZ hardware, byte-exact on the
# host, with the bounded loopback test surface.
#
# Mechanism: the guest's UDP layer (kernel/src/udp.zig) sits on the N4
# IPv4 seam — ipv4.zig's protocol dispatch hands validated protocol-17
# frames to udp.handle_rx, which checks the pseudo-header checksum,
# looks up the dst port in a bounded 4-slot LISTEN table (net udp listen
# <port>), and delivers into that listener's bounded datagram buffer
# (net udp recv prints it byte-exact). net udp send <ip> <port> <len>
# transmits ONE datagram (fixed src port 7000, the byte-index payload)
# on the N1 TX path for a resolved peer — and a send to OUR OWN IP
# takes the LOOPBACK path (delivered directly into the local receive
# path, NO device round trip). The runner's --net-inject (card N2)
# delivers the host's crafted datagrams at the net-ip serial marker;
# the new --net-udp-respond <host-ip>:<host-port> flag (card N5)
# answers the guest's datagrams from the host side inside the capture
# thread (the SAME payload echoed byte-exact, checksums recomputed).
#
# Phase 1 (loopback — no host involvement): net udp listen 7000, then
# net udp send 10.0.0.1 7000 4 (OUR OWN IP) -> the 12-byte datagram is
# delivered DIRECTLY into the listener's buffer (net udp recv prints it
# byte-exact: src 7000, dst 7000, len 12, payload 01 02 03 04), the
# counters move (rx=1, tx=1, loop=1), and the host capture stays EMPTY
# (nothing hit the device). The bounded loopback test surface, live.
#
# Phase 2 (host -> guest): the runner injects the 46-byte UDP datagram
# 10.0.0.2:9999 -> 10.0.0.1:7000 (payload 01 02 03 04, pseudo-header
# checksum) at the ip-set marker -> net udp recv prints it byte-exact,
# net recv observes the raw frame (device len 58 = 12-byte RX header +
# 46), rx=1, drop=0.
#
# Phase 3 (guest -> host round trip): net arp 10.0.0.2 (resolve) + net
# udp send 10.0.0.2 9999 4 -> the 46-byte datagram (src 10.0.0.1:7000)
# is byte-exact in the host capture AND --net-udp-respond
# 10.0.0.2:9999's answer (FROM 10.0.0.2:9999 TO 10.0.0.1:7000, the
# SAME payload) lands in the listener's buffer: net udp recv shows the
# 12-byte answer, rx=1, tx=1.
#
# Phase 4 (scope check): inject a UDP datagram to 10.0.0.1:9998 (a
# CLOSED port) -> no delivery (net udp recv: no datagrams), the drop
# counter moves (drop=1), no reply (the guest does not answer UDP), and
# the frame is still observable via net recv (the N2 seam regression —
# a drop is a counter, not a swallowed frame).
#
# The gate only ever adds the --net/--net-inject/--net-udp-respond
# surface: the default VM is untouched, and the FULL 33-gate verify-vz
# aggregate must stay green (re-run separately).
#
# Honesty: the runner exits 0 only when the expected transcript appears;
# the gate additionally asserts every transcript line AND compares the
# capture bytes, so an early exit on the echoed input line cannot pass.
# Evidence under artifacts/: live-net-udp-*.txt (runner output),
# live-net-udp-*.log (serial copies), live-net-udp-*.bin (host
# captures), and the report.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-net-udp.sh
#
# Evidence: artifacts/live-net-udp-gate.txt (full output),
# artifacts/live-net-udp-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-net-udp-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-net-udp-report.txt"

echo "=== verify-live-net-udp: claim 8552 — UDP live on VZ (loopback, host->guest, round trip, closed-port scope check) ==="

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
# TWO script phases per run (the claim-4613 pattern): --script (phase 1)
# sets the IP + the listener and prints a ready marker; the runner's
# --net-inject fires at the ip-set echo (20 ms marker poll); the frame is
# delivered and drained within ~50 ms; then --script2 (forwarded only
# after the ready marker, with the claim-6684 0.5 s settle) runs the
# OBSERVATION commands — deterministic, not a sleep race. Phase 1
# (loopback) has NO injection: the send + recv are synchronous in script2
# (the loopback path never touches the device).
cat > artifacts/live-net-udp-script-1.txt <<'EOF'
net ip 10.0.0.1
net udp listen 7000
echo udp-phase1-ready
EOF
cat > artifacts/live-net-udp-script-1b.txt <<'EOF'
net udp send 10.0.0.1 7000 4
net udp recv 7000
net udp
echo net-udp-ok
EOF
cat > artifacts/live-net-udp-script-2.txt <<'EOF'
net ip 10.0.0.1
net udp listen 7000
echo udp-phase1-ready
EOF
cat > artifacts/live-net-udp-script-2b.txt <<'EOF'
net udp recv 7000
net recv
net
echo net-udp-ok
EOF
cat > artifacts/live-net-udp-script-3.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net udp listen 7000
echo udp-phase3-ready
EOF
cat > artifacts/live-net-udp-script-3b.txt <<'EOF'
net udp send 10.0.0.2 9999 4
net udp recv 7000
net udp recv 7000
net
echo net-udp-ok
EOF
cat > artifacts/live-net-udp-script-4.txt <<'EOF'
net ip 10.0.0.1
echo udp-phase1-ready
EOF
cat > artifacts/live-net-udp-script-4b.txt <<'EOF'
net udp recv 9998
net recv
net
echo net-udp-ok
EOF

# --- byte-exact fixtures (the class-A build_frame / checksum shapes) --------
# p2: the 46-byte UDP frame the HOST injects (10.0.0.2:9999 ->
#     10.0.0.1:7000, payload 01 02 03 04) + the datagram hex the guest's
#     net udp recv prints for it. The host ANSWER in phase 3 carries the
#     SAME datagram (10.0.0.2:9999 -> 10.0.0.1:7000), so the recv hex is
#     shared.
# p3: the guest's own send frame (10.0.0.1:7000 -> 10.0.0.2:9999, ident
#     0x0000, TTL 64) — the expected capture bytes.
# p4: the 46-byte frame to a CLOSED port (10.0.0.1:9998).
python3 - <<'PY'
def csum(b):
    s = 0
    for i in range(0, len(b) - 1, 2):
        s += (b[i] << 8) | b[i + 1]
    if len(b) % 2:
        s += b[-1] << 8
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff

def udp_frame(dst_mac, src_mac, src_ip, dst_ip, src_port, dst_port, payload, ident=1, ttl=64):
    buf = bytearray(46)
    buf[0:6] = dst_mac
    buf[6:12] = src_mac
    buf[12:14] = b"\x08\x00"
    buf[14] = 0x45
    buf[16:18] = (32).to_bytes(2, "big")  # total length 20+8+4
    buf[18:20] = ident.to_bytes(2, "big")
    buf[22] = ttl
    buf[23] = 17
    buf[26:30] = src_ip
    buf[30:34] = dst_ip
    c = csum(bytes(buf[14:34]))
    buf[24:26] = c.to_bytes(2, "big")
    udp = bytearray(8 + len(payload))
    udp[0:2] = src_port.to_bytes(2, "big")
    udp[2:4] = dst_port.to_bytes(2, "big")
    udp[4:6] = (8 + len(payload)).to_bytes(2, "big")
    udp[8:] = payload
    # The IPv4 pseudo-header: src IP, dst IP, zero, protocol 17, UDP length.
    ph = bytes(src_ip) + bytes(dst_ip) + b"\x00\x11" + (8 + len(payload)).to_bytes(2, "big")
    c2 = csum(ph + bytes(udp))
    udp[6:8] = c2.to_bytes(2, "big")
    buf[34:46] = udp
    return bytes(buf)

host_mac = [0x02,0,0,0,0,2]
guest_mac = [0x02,0,0,0,0,1]
host_ip = [10,0,0,2]
guest_ip = [10,0,0,1]
bcast = [0xff]*6
payload = b"\x01\x02\x03\x04"

# p2: host -> guest datagram (dst = broadcast so the MAC filter accepts)
req2 = udp_frame(bcast, host_mac, host_ip, guest_ip, 9999, 7000, payload, ident=0xabcd)
assert len(req2) == 46, len(req2)
open("artifacts/live-net-udp-fixture-2.bin","wb").write(req2)
# p3: the guest's own send frame (dst = host MAC, ident 0x0000 —
# build_frame leaves the identification field zero). The capture holds
# BOTH the script-1 resolve's broadcast ARP request AND the script-2
# send's datagram, in order — the fixture is the concatenation.
def arp_pkt(dst, src, op, sha, spa, tha, tpa):
    return (bytes(dst) + bytes(src) + bytes([0x08,0x06])
            + bytes([0x00,0x01,0x08,0x00,0x06,0x04])
            + bytes([op>>8, op&0xff])
            + bytes(sha) + bytes(spa) + bytes(tha) + bytes(tpa))
req3_arp = arp_pkt(bcast, guest_mac, 1, guest_mac, guest_ip, [0]*6, host_ip)
assert len(req3_arp) == 42, len(req3_arp)
req3_udp = udp_frame(host_mac, guest_mac, guest_ip, host_ip, 7000, 9999, payload, ident=0)
assert len(req3_udp) == 46, len(req3_udp)
open("artifacts/live-net-udp-fixture-3.bin","wb").write(req3_arp + req3_udp)
# p4: a datagram to a CLOSED port (10.0.0.1:9998)
req4 = udp_frame(bcast, host_mac, host_ip, guest_ip, 9999, 9998, payload, ident=1)
assert len(req4) == 46, len(req4)
open("artifacts/live-net-udp-fixture-4.bin","wb").write(req4)

# The datagram hex the guest's net udp recv prints. For the loopback
# (phase 1): src 7000 -> dst 7000, len 12, checksum, payload. For the
# host datagrams (phases 2 + the phase-3 answer): src 9999 -> dst 7000,
# len 12, checksum, payload. The checksum is the SAME datagram the guest
# verifies — deterministic, byte-exact.
def datagram_hex(src_port, dst_port, plen):
    dg = bytearray(8 + plen)
    dg[0:2] = src_port.to_bytes(2, "big")
    dg[2:4] = dst_port.to_bytes(2, "big")
    dg[4:6] = (8 + plen).to_bytes(2, "big")
    dg[8:] = payload
    # The loopback pseudo-header: src == dst == 10.0.0.1; the host
    # datagrams: 10.0.0.2 -> 10.0.0.1. Only the header differs; the
    # delivered datagram bytes (ports/len/checksum/payload) are computed
    # here exactly as udp.build_datagram would.
    src = guest_ip if src_port == 7000 and dst_port == 7000 else host_ip
    dst = guest_ip
    ph = bytes(src) + bytes(dst) + b"\x00\x11" + (8 + plen).to_bytes(2, "big")
    c2 = csum(ph + bytes(dg))
    dg[6:8] = c2.to_bytes(2, "big")
    return " ".join("%02x" % x for x in dg)

def recv_line(dg_hex):
    return "net udp recv: " + dg_hex

open("artifacts/live-net-udp-recv-1.txt","w").write(recv_line(datagram_hex(7000, 7000, 4)))
open("artifacts/live-net-udp-recv-2.txt","w").write(recv_line(datagram_hex(9999, 7000, 4)))
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
        --net "$capture" ${ARGS[@]+"${ARGS[@]}"} --script "$script" --script2 "$script2" --script2-after "$after2" --script-expect $'net-udp-ok\ndipshit> ' --timeout 40 \
        > "artifacts/live-net-udp-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-net-udp-serial-$tag.log" || true

    local SERIAL_BYTES=0 IPSET=0 RECV=0 RECVLEN=0 RECVEXACT=0 RX1=0 TX1=0 LOOP=0 DROP=0 SENT=0 SENDLINE=0 NOFRAMES=0 FRAMELEN=0
    if [ -f artifacts/vm-serial.log ]; then
        SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log | tr -d ' ')
        # The static-IP marker (also the injection trigger).
        grep -a -qF -- "net ip: ip=10.0.0.1" artifacts/vm-serial.log && IPSET=1
        case "$tag" in
            p1)
                grep -a -qF -- "net udp recv: port=7000" artifacts/vm-serial.log && RECV=1
                grep -a -qF -- "net udp recv: [0] len=12" artifacts/vm-serial.log && RECVLEN=1
                grep -a -qF -- "$(cat artifacts/live-net-udp-recv-1.txt)" artifacts/vm-serial.log && RECVEXACT=1
                grep -a -qF -- "net udp: rx=1,tx=1,loop=1,drop=0" artifacts/vm-serial.log && RX1=1
                grep -a -qF -- "net-udp-ok" artifacts/vm-serial.log && SENT=1
                ;;
            p2)
                grep -a -qF -- "net udp recv: port=7000" artifacts/vm-serial.log && RECV=1
                grep -a -qF -- "net udp recv: [0] len=12" artifacts/vm-serial.log && RECVLEN=1
                grep -a -qF -- "$(cat artifacts/live-net-udp-recv-2.txt)" artifacts/vm-serial.log && RECVEXACT=1
                grep -a -qF -- "net recv: [0] len=58" artifacts/vm-serial.log && FRAMELEN=1
                grep -a -qF -- " udp=rx=1,tx=0,loop=0,drop=0" artifacts/vm-serial.log && RX1=1
                grep -a -qF -- "net-udp-ok" artifacts/vm-serial.log && SENT=1
                ;;
            p3)
                grep -a -qF -- "net udp: sent 4 bytes to 10.0.0.2:9999 (46 bytes)" artifacts/vm-serial.log && SENDLINE=1
                grep -a -qF -- "net udp recv: port=7000" artifacts/vm-serial.log && RECV=1
                grep -a -qF -- "net udp recv: [0] len=12" artifacts/vm-serial.log && RECVLEN=1
                grep -a -qF -- "$(cat artifacts/live-net-udp-recv-2.txt)" artifacts/vm-serial.log && RECVEXACT=1
                grep -a -qF -- " udp=rx=1,tx=1,loop=0,drop=0" artifacts/vm-serial.log && RX1=1
                grep -a -qF -- "net-udp-ok" artifacts/vm-serial.log && SENT=1
                ;;
            p4)
                # Nothing delivered (the port is closed)...
                grep -a -qF -- "net udp recv: no datagrams for port 9998" artifacts/vm-serial.log && NOFRAMES=1
                # ...but the frame IS observable via net recv (the N2 seam).
                grep -a -qF -- "net recv: [0] len=58" artifacts/vm-serial.log && FRAMELEN=1
                grep -a -qF -- " udp=rx=0,tx=0,loop=0,drop=1" artifacts/vm-serial.log && DROP=1
                grep -a -qF -- "net-udp-ok" artifacts/vm-serial.log && SENT=1
                ;;
        esac
    fi
    # Per-phase pass: every phase needs rc + the ip-set marker + the
    # session echo; the protocol flags are phase-specific.
    local PASS=0
    case "$tag" in
        p1)
            [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$RECV" = 1 ] && [ "$RECVLEN" = 1 ] && [ "$RECVEXACT" = 1 ] && [ "$RX1" = 1 ] && [ "$SENT" = 1 ] && PASS=1
            ;;
        p2)
            [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$RECV" = 1 ] && [ "$RECVLEN" = 1 ] && [ "$RECVEXACT" = 1 ] && [ "$FRAMELEN" = 1 ] && [ "$RX1" = 1 ] && [ "$SENT" = 1 ] && PASS=1
            ;;
        p3)
            [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$SENDLINE" = 1 ] && [ "$RECV" = 1 ] && [ "$RECVLEN" = 1 ] && [ "$RECVEXACT" = 1 ] && [ "$RX1" = 1 ] && [ "$SENT" = 1 ] && PASS=1
            ;;
        p4)
            [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$NOFRAMES" = 1 ] && [ "$FRAMELEN" = 1 ] && [ "$DROP" = 1 ] && [ "$SENT" = 1 ] && PASS=1
            ;;
    esac
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES ip-set=$IPSET recv=$RECV recv-len=$RECVLEN recv-exact=$RECVEXACT rx1=$RX1 sendline=$SENDLINE noframes=$NOFRAMES framelen=$FRAMELEN drop=$DROP sent=$SENT pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES ip-set=$IPSET recv=$RECV recv-len=$RECVLEN recv-exact=$RECVEXACT rx1=$RX1 sendline=$SENDLINE noframes=$NOFRAMES framelen=$FRAMELEN drop=$DROP sent=$SENT pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live UDP gate (claim 8552, milestone five card N5) — loopback, host->guest, round trip, closed-port scope check, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase 1: net udp send 10.0.0.1 7000 4 (our OWN IP) -> net udp recv prints the 12-byte datagram byte-exact (src 7000, dst 7000), rx=1 tx=1 loop=1, the capture stays EMPTY (no device round trip)"
    echo "phase 2: inject 10.0.0.2:9999 -> 10.0.0.1:7000 -> net udp recv prints it byte-exact, net recv observes the frame (len 58), rx=1 drop=0"
    echo "phase 3: net arp 10.0.0.2 + net udp send 10.0.0.2 9999 4 -> the 46-byte datagram is byte-exact in the capture AND --net-udp-respond 10.0.0.2:9999's answer (same payload) lands in the listener buffer, rx=1 tx=1"
    echo "phase 4: inject a datagram to a CLOSED port (10.0.0.1:9998) -> no delivery (no datagrams), drop=1, no reply, the frame still observable via net recv"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
PHASES=0

echo
    echo "=== phase 1: loopback — send to our own IP delivers locally, no device round trip ==="
    P1=0
    run_one "p1" "artifacts/live-net-udp-script-1.txt" "artifacts/live-net-udp-script-1b.txt" "udp-phase1-ready" "" "artifacts/live-net-udp-cap-1.bin" "" && P1=1 || true
    CAP1=0
    if [ ! -f artifacts/live-net-udp-cap-1.bin ] || [ ! -s artifacts/live-net-udp-cap-1.bin ]; then
        CAP1=1
    fi
    echo "phase 1 capture-empty=$CAP1"
    [ "$CAP1" = 1 ] && [ "$P1" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

    echo
    echo "=== phase 2: host -> guest — the injected datagram is delivered to the listener, byte-exact ==="
    P2=0
    run_one "p2" "artifacts/live-net-udp-script-2.txt" "artifacts/live-net-udp-script-2b.txt" "udp-phase1-ready" "artifacts/live-net-udp-fixture-2.bin" "artifacts/live-net-udp-cap-2.bin" "" && P2=1 || true
    echo "phase 2 pass=$P2"
    [ "$P2" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

    echo
    echo "=== phase 3: guest -> host round trip — the datagram is byte-exact in the capture and the host answer lands in the listener buffer ==="
    P3=0
    run_one "p3" "artifacts/live-net-udp-script-3.txt" "artifacts/live-net-udp-script-3b.txt" "udp-phase3-ready" "" "artifacts/live-net-udp-cap-3.bin" "--net-arp-respond 10.0.0.2 --net-udp-respond 10.0.0.2:9999" && P3=1 || true
    CAP3=0
    for _ in 1 2 3 4 5; do
        if [ -f artifacts/live-net-udp-cap-3.bin ] && cmp -s artifacts/live-net-udp-cap-3.bin artifacts/live-net-udp-fixture-3.bin; then
            CAP3=1
            break
        fi
        sleep 0.5
    done
    echo "phase 3 capture-datagram-exact=$CAP3"
    [ "$CAP3" = 1 ] && [ "$P3" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

    echo
    echo "=== phase 4: a datagram to a CLOSED port is dropped (scope check) ==="
    P4=0
    run_one "p4" "artifacts/live-net-udp-script-4.txt" "artifacts/live-net-udp-script-4b.txt" "udp-phase1-ready" "artifacts/live-net-udp-fixture-4.bin" "artifacts/live-net-udp-cap-4.bin" "" && P4=1 || true
    CAP4=0
    if [ ! -f artifacts/live-net-udp-cap-4.bin ] || [ ! -s artifacts/live-net-udp-cap-4.bin ]; then
        CAP4=1
    fi
    echo "phase 4 capture-empty=$CAP4"
    [ "$CAP4" = 1 ] && [ "$P4" = 1 ] && PASS=$((PASS + 1))
    PHASES=$((PHASES + 1))

echo
echo "=== result ==="
if [ "$PASS" = "$PHASES" ]; then
    echo "verify-live-net-udp: PASS — UDP is live on VZ: the loopback path delivers a send to our own IP DIRECTLY into the listener's buffer (byte-exact recv, rx=1 tx=1 loop=1, capture empty — no device round trip), the host's injected datagram is delivered to the listener byte-exact (device len 58, rx=1 drop=0), the guest's send to a resolved peer is byte-exact in the capture AND the runner's --net-udp-respond answer lands in the listener buffer (rx=1 tx=1), and a datagram to a closed port is dropped with a counter while remaining observable via net recv (the N2 seam intact). ($PASS/$PHASES phases)."
    echo "PASS: $PASS/$PHASES" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-net-udp: FAILED — $PASS/$PHASES phases passed; see artifacts/live-net-udp-report.txt, the per-phase runner output and serial logs, and the capture files."
    echo "FAIL: $PASS/$PHASES" >> "$REPORT"
    sleep 0.5
    exit 1
fi
