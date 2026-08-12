#!/usr/bin/env bash
#
# verify-live-net-udp-syscall.sh -- claim 1384 (milestone five, card N6)
# class-B gate: the UDP syscall seam observed end to end on real VZ
# hardware — a USER PROGRAM (UDP.BIN, loaded by `exec`) drives the
# milestone-five UDP layer through the ADR 0007 slots 9/10/11
# (sys_udp_listen / sys_udp_send / sys_udp_recv) entirely from EL0.
#
# Mechanism: the kernel's N5 UDP layer (kernel/src/udp.zig) sits on the
# N4 IPv4 seam; the N6 seam (kernel/src/syscall.zig slots 9/10/11) wraps
# it — listen_port / net_udp_send (own-IP LOOPBACK, no device round
# trip) / peek+pop — with every byte across the claim-6120 uaccess
# window. UDP.BIN (user/src/udp.zig) runs the whole flow:
#
#   sys_udp_listen(7000)  -> "udp: listen ok"
#   sys_udp_send(10.0.0.1, 7000, "ping", 4)  -> LOOPBACK (no device)
#   sys_udp_recv(7000)    -> the 12-byte datagram -> "udp: loop ping"
#   sys_udp_send(10.0.0.2, 9999, "ping", 4)   -> the 46-byte datagram is
#     byte-exact in the host capture (the peer MAC is resolved first by
#     the gate's `net arp 10.0.0.2`; a send refused with EINVAL while the
#     ARP reply is still in flight is RETRIED with a cooperative yield —
#     bounded)
#   sys_udp_recv(7000)    -> polls until --net-udp-respond 10.0.0.2:9999's
#     answer (the SAME payload echoed) lands -> "udp: got ping"
#   sys_udp_recv(9998)    -> an UNBOUND port -> EINVAL (-1) -> "udp: recv
#     err -1" (the error mapping, observed from EL0)
#   sys_udp_send(10.0.0.99, 9999, ...) -> an UNRESOLVED peer -> .no_peer
#     -> EINVAL (-1) -> "udp: send err -1" (nothing transmitted)
#   sys_exit(17)          -> the reap reports: `procs UDP.BIN exited
#     status=17` / `tasks user-exec exited status=17` / `tasks user-exec
#     reaped`
#
# After the program exits, script2 (the 0.5 s settle pattern) runs the
# OBSERVATION commands on the SAME kernel state: `syscalls` (the report
# now prints rows 0-11 — implemented=12, rows 9/10/11 with calls > 0)
# and `net udp` / `net` (the counters rx=2, tx=2, loop=1, drop=0 — the
# loopback + the round trip, visible in the SAME monitor surface the
# N5 gate greps).
#
# The host capture holds the ARP request (42 bytes, from `net arp
# 10.0.0.2`) followed by the program's 46-byte datagram (src
# 10.0.0.1:7000 -> 10.0.0.2:9999, payload "ping") — the byte-exact
# concatenation fixture (the N5 phase-3 shape). Nothing else is
# transmitted (the EINVAL sends never touch the device).
#
# The gate only uses the EXISTING --net / --net-arp-respond /
# --net-udp-respond surface: the default VM is untouched, and the FULL
# 34-gate verify-vz aggregate must stay green (re-run separately).
#
# Honesty: the runner exits 0 only when the expected transcript appears;
# the gate additionally asserts every marker IN ORDER and compares the
# capture bytes, so an early exit on the echoed input line cannot pass.
# Evidence under artifacts/: live-net-udp-syscall-*.txt (runner output),
# live-net-udp-syscall-*.log (serial copies), the .bin (host capture),
# and the report.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-net-udp-syscall.sh
#
# Evidence: artifacts/live-net-udp-syscall-gate.txt (full output),
# artifacts/live-net-udp-syscall-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-net-udp-syscall-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-net-udp-syscall-report.txt"

echo "=== verify-live-net-udp-syscall: claim 1384 — the UDP syscall seam live on VZ (UDP.BIN from EL0: listen, loopback, round trip, EINVAL errors, exit) ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- scripted keystrokes -----------------------------------------------------
# ONE VM session, TWO script phases (the claim-4613 pattern): --script
# (phase 1) sets the IP, resolves the host peer, exec's UDP.BIN, and
# prints a ready marker; --script2 runs the OBSERVATION commands.
# TIMING (observed live): the session must outlive the program's whole
# lifecycle — UDP.BIN only reaches its poll once the ring returns to it
# (~4 s of 1 s ticks with the 5-task pool), so --script2 is keyed on the
# program's OWN `udp: got ping` marker (not the early ready marker) and
# --script-expect on the reap line `tasks user-exec reaped` (not an
# early echo) — an early expect would kill the VM before the round trip
# completed and the gate would fail on a healthy kernel. Deterministic,
# not a sleep race. The program's markers land in the log before the
# observation phase.
cat > artifacts/live-net-udp-syscall-script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec UDP.BIN
echo udp-syscall-ready
EOF
cat > artifacts/live-net-udp-syscall-script-2.txt <<'EOF'
syscalls
tasks
net udp
net
echo net-udp-ok
EOF

# --- byte-exact fixtures (the class-A build_frame / checksum shapes) --------
# The capture holds the guest's broadcast ARP request ("who has
# 10.0.0.2, tell 10.0.0.1" — 42 bytes) followed by UDP.BIN's 46-byte
# datagram (src 10.0.0.1:7000 -> 10.0.0.2:9999, payload "ping", ident
# 0x0000, TTL 64). The EINVAL sends never reach the device.
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

def arp_pkt(dst, src, op, sha, spa, tha, tpa):
    return (bytes(dst) + bytes(src) + bytes([0x08, 0x06])
            + bytes([0x00, 0x01, 0x08, 0x00, 0x06, 0x04])
            + bytes([op >> 8, op & 0xff])
            + bytes(sha) + bytes(spa) + bytes(tha) + bytes(tpa))

def udp_frame(dst_mac, src_mac, src_ip, dst_ip, src_port, dst_port, payload, ident=0, ttl=64):
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

host_mac = [0x02, 0, 0, 0, 0, 2]
guest_mac = [0x02, 0, 0, 0, 0, 1]
host_ip = [10, 0, 0, 2]
guest_ip = [10, 0, 0, 1]
bcast = [0xff] * 6
payload = b"ping"

req_arp = arp_pkt(bcast, guest_mac, 1, guest_mac, guest_ip, [0] * 6, host_ip)
assert len(req_arp) == 42, len(req_arp)
req_udp = udp_frame(host_mac, guest_mac, guest_ip, host_ip, 7000, 9999, payload, ident=0)
assert len(req_udp) == 46, len(req_udp)
open("artifacts/live-net-udp-syscall-fixture.bin", "wb").write(req_arp + req_udp)
print("fixture: %d bytes (42-byte ARP request + 46-byte datagram)" % len(req_arp + req_udp))
PY

# --- the run ----------------------------------------------------------------
rm -f artifacts/efi-vars.bin artifacts/vm-serial.log artifacts/live-net-udp-syscall-cap.bin
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --net artifacts/live-net-udp-syscall-cap.bin \
    --net-arp-respond 10.0.0.2 --net-udp-respond 10.0.0.2:9999 \
    --script artifacts/live-net-udp-syscall-script-1.txt \
    --script2 artifacts/live-net-udp-syscall-script-2.txt --script2-after 'udp: got ping' \
    --script-expect $'tasks user-exec reaped' --timeout 90 \
    > artifacts/live-net-udp-syscall-run.txt 2>&1
RC=$?
set -e
[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-net-udp-syscall-serial.log || true

# --- assertions -------------------------------------------------------------
SERIAL="artifacts/vm-serial.log"
SERIAL_BYTES=0; IPSET=0
LISTEN=0; LOOP=0; GOT=0; RECVERR=0; SENDERR=0; ORDER=0
EXITP=0; EXITT=0; REAPED=0
SYSCOUNT=0; ROWS=0; UDPCOUNTERS=0; NETCOUNTERS=0; OK=0
if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IPSET=1
    # The UDP.BIN markers, IN ORDER (the claim-1014 line-number pattern).
    # An absent marker makes grep exit 1; under `set -euo pipefail` the
    # bare substitution would kill the gate BEFORE it can report the FAIL
    # (observed live: the round trip had not completed when the report was
    # taken, and the gate died silently with no report file). The `|| true`
    # keeps the assignment at exit 0 — an absent marker is just an empty
    # value and the phase-1 assertion below honestly fails.
    l_listen=$(grep -a -nF -- "udp: listen ok" "$SERIAL" | head -1 | cut -d: -f1 || true)
    l_loop=$(grep -a -nF -- "udp: loop ping" "$SERIAL" | head -1 | cut -d: -f1 || true)
    l_got=$(grep -a -nF -- "udp: got ping" "$SERIAL" | head -1 | cut -d: -f1 || true)
    l_recverr=$(grep -a -nF -- "udp: recv err -1" "$SERIAL" | head -1 | cut -d: -f1 || true)
    l_senderr=$(grep -a -nF -- "udp: send err -1" "$SERIAL" | head -1 | cut -d: -f1 || true)
    l_exit=$(grep -a -nF -- "procs UDP.BIN exited status=17" "$SERIAL" | head -1 | cut -d: -f1 || true)
    [ -n "$l_listen" ] && [ -n "$l_loop" ] && [ -n "$l_got" ] && [ -n "$l_recverr" ] && [ -n "$l_senderr" ] && [ -n "$l_exit" ] && \
        [ "$l_listen" -lt "$l_loop" ] && [ "$l_loop" -lt "$l_got" ] && [ "$l_got" -lt "$l_recverr" ] && [ "$l_recverr" -lt "$l_senderr" ] && [ "$l_senderr" -lt "$l_exit" ] && ORDER=1
    [ -n "$l_listen" ] && LISTEN=1
    [ -n "$l_loop" ] && LOOP=1
    [ -n "$l_got" ] && GOT=1
    [ -n "$l_recverr" ] && RECVERR=1
    [ -n "$l_senderr" ] && SENDERR=1
    [ -n "$l_exit" ] && EXITP=1
    grep -a -qF -- "tasks user-exec exited status=17" "$SERIAL" && EXITT=1
    grep -a -qF -- "tasks user-exec reaped" "$SERIAL" && REAPED=1
    # The observation phase (script2): the syscall report now prints rows
    # 0-11 (implemented=12) and the seam rows show real call counts.
    grep -a -qF -- "syscalls: slots=64 implemented=12" "$SERIAL" && SYSCOUNT=1
    for row in "  9 sys_udp_listen calls=" "  10 sys_udp_send calls=" "  11 sys_udp_recv calls="; do
        if grep -a -qF -- "$row" "$SERIAL" && ! grep -a -qF -- "${row}0" "$SERIAL"; then
            ROWS=$((ROWS + 1))
        fi
    done
    # The counters: loopback + the round trip — rx=2 (loopback + the
    # host answer), tx=2 (loopback + the peer datagram), loop=1, drop=0.
    grep -a -qF -- "net udp: rx=2,tx=2,loop=1,drop=0" "$SERIAL" && UDPCOUNTERS=1
    grep -a -qF -- " udp=rx=2,tx=2,loop=1,drop=0" "$SERIAL" && NETCOUNTERS=1
    grep -a -qF -- "net-udp-ok" "$SERIAL" && OK=1
fi

# The capture: the ARP request + the datagram, byte-exact.
CAPTURE=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -f artifacts/live-net-udp-syscall-cap.bin ] && cmp -s artifacts/live-net-udp-syscall-cap.bin artifacts/live-net-udp-syscall-fixture.bin; then
        CAPTURE=1
        break
    fi
    sleep 0.5
done
CAPSIZE=0
[ -f artifacts/live-net-udp-syscall-cap.bin ] && CAPSIZE=$(wc -c < artifacts/live-net-udp-syscall-cap.bin | tr -d ' ')

{
    echo "DIPSHITOS live UDP-syscall gate (claim 1384, milestone five card N6) — UDP.BIN from EL0 on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase 1: exec UDP.BIN — sys_udp_listen(7000) -> 'udp: listen ok'; loopback send+recv -> 'udp: loop ping'; peer send (10.0.0.2:9999) + poll recv of the host's echoed answer -> 'udp: got ping'; unbound-port recv + unresolved-peer send -> 'udp: recv err -1' / 'udp: send err -1' (EINVAL from EL0); sys_exit(17) -> 'procs UDP.BIN exited status=17' — the markers IN ORDER"
    echo "phase 1 capture: the 42-byte ARP request + the 46-byte datagram (src 10.0.0.1:7000 -> 10.0.0.2:9999, payload 'ping') byte-exact"
    echo "phase 2: syscalls (implemented=12, rows 9/10/11 with calls > 0) + net udp / net counters (rx=2, tx=2, loop=1, drop=0)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

# --- result -----------------------------------------------------------------
PASS=0
[ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$LISTEN" = 1 ] && [ "$LOOP" = 1 ] && [ "$GOT" = 1 ] && [ "$RECVERR" = 1 ] && [ "$SENDERR" = 1 ] && [ "$ORDER" = 1 ] && PASS=$((PASS + 1))
[ "$EXITP" = 1 ] && [ "$EXITT" = 1 ] && [ "$REAPED" = 1 ] && PASS=$((PASS + 1))
[ "$CAPTURE" = 1 ] && PASS=$((PASS + 1))
[ "$SYSCOUNT" = 1 ] && [ "$ROWS" = 3 ] && [ "$UDPCOUNTERS" = 1 ] && [ "$NETCOUNTERS" = 1 ] && [ "$OK" = 1 ] && PASS=$((PASS + 1))

{
    echo "rc=$RC serial-bytes=$SERIAL_BYTES ip-set=$IPSET"
    echo "markers: listen=$LISTEN loop=$LOOP got=$GOT recv-err=$RECVERR send-err=$SENDERR order=$ORDER"
    echo "exit: procs=$EXITP tasks=$EXITT reaped=$REAPED"
    echo "capture-exact=$CAPTURE capture-bytes=$CAPSIZE (fixture: 88)"
    echo "observation: syscalls-report=$SYSCOUNT rows-with-calls=$ROWS/3 net-udp-counters=$UDPCOUNTERS net-counters=$NETCOUNTERS ok=$OK"
    echo "phases passed: $PASS/4"
} >> "$REPORT"

echo "rc=$RC serial-bytes=$SERIAL_BYTES ip-set=$IPSET"
echo "markers: listen=$LISTEN loop=$LOOP got=$GOT recv-err=$RECVERR send-err=$SENDERR order=$ORDER"
echo "exit: procs=$EXITP tasks=$EXITT reaped=$REAPED"
echo "capture-exact=$CAPTURE capture-bytes=$CAPSIZE (fixture: 88)"
echo "observation: syscalls-report=$SYSCOUNT rows-with-calls=$ROWS/3 net-udp-counters=$UDPCOUNTERS net-counters=$NETCOUNTERS ok=$OK"

echo
echo "=== result ==="
if [ "$PASS" = 4 ]; then
    echo "verify-live-net-udp-syscall: PASS — the UDP syscall seam is live on VZ: UDP.BIN (a USER PROGRAM loaded by exec) bound port 7000 through sys_udp_listen, loopback-sent and received through sys_udp_send/sys_udp_recv (the 12-byte datagram, byte-exact), sent the 46-byte datagram to 10.0.0.2:9999 (byte-exact in the capture behind the ARP request) and received the host's --net-udp-respond answer, observed the EINVAL error mapping from EL0 (unbound-port recv, unresolved-peer send), and exited with status 17 (the reap reports landed); the observation phase shows implemented=12 with rows 9/10/11 counted and the shared counters rx=2 tx=2 loop=1 drop=0. ($PASS/4 phases)."
    echo "PASS: $PASS/4" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-net-udp-syscall: FAILED — $PASS/4 phases passed; see artifacts/live-net-udp-syscall-report.txt, the runner output, the serial log, and the capture file."
    echo "FAIL: $PASS/4" >> "$REPORT"
    sleep 0.5
    exit 1
fi
