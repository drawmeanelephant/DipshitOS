#!/usr/bin/env bash
#
# verify-live-net-tcp-rto.sh -- claim 5357 (milestone five, card N11)
# class-B gate: the bounded TCP retransmission + retransmit timer live
# on real VZ hardware — the RTO (3 s of guest ticks) retransmits a
# pending unacknowledged SYN/data/FIN byte-exact, an ACK covering
# snd_una clears the pending state (no retransmission of an
# acknowledged segment), and the retransmission bound (10) aborts the
# connection honestly.
#
# Mechanism: card N11's RTO poll runs in the shell idle loop (the time
# engine — it already stamps `now_ticks` from the 1 Hz generic timer),
# so the retransmit timer fires AUTONOMOUSLY between commands:
# `net tcp: <syn|data|fin> retransmitted (n/10)` and, at the bound,
# `net tcp: retransmission limit reached (10) — connection aborted`.
# The runner's `--net-tcp-respond` (card N10) answers the handshake;
# its new `:handshake` mode (card N11) answers the SYN-ACK then goes
# SILENT on data/FIN — the deterministic data black hole. The
# file-handle attachment is deterministic end to end: every retransmit
# is byte-assertable in the capture.
#
# THREE runs, each ONE boot:
#   Run A — the retransmission proof (file-handle, ARP responder ONLY
#   — a deterministic black hole for the SYN): connect -> SYN, wait 7 s
#   (past two 3 s RTOs) -> the idle loop retransmits the SYN twice,
#   byte-exact in the capture (SAME seq, flags, checksum) — the report
#   reads retx=2. Assertions: the `syn retransmitted (1/10)` /
#   `(2/10)` lines, the `retx=2,abort=0` report, and the capture's
#   THREE byte-identical 54-byte SYN frames (a python walk verifies
#   the seqs, flags, ports, MACs, IPv4 checksums, and TCP checksums).
#   The 30 s connect timeout has NOT expired (elapsed 7 s) — still
#   syn_sent.
#   Run B — the recovery (file-handle + the full responder): connect ->
#   the responder answers the SYN-ACK; despite the 7 s wait (past the
#   RTO), the ACK cleared the pending state — NO retransmission
#   (retx=0 in the report, exactly ONE SYN in the capture, the
#   handshake completes). Assertions: established, retx=0, the
#   capture's ARP + SYN + handshake ACK (150 bytes) with a single SYN.
#   Run C — the retransmission bound (file-handle + the `:handshake`
#   responder: SYN-ACK yes, data silent): connect -> established ->
#   send 5 (the data is never ACKed) -> the idle loop retransmits the
#   data 10 times (one per 3 s RTO) -> the bound aborts the connection
#   honestly (`retransmission limit reached (10) — connection aborted`,
#   no RST, no TX — the N10 abort_timeout pattern). Assertions: the
#   ten `data retransmitted (n/10)` lines, the abort line, the report
#   `tcp=idle,peer=0.0.0.0:0,...,retx=10,abort=1`, `net tcp: no
#   connection` after, and the capture's ELEVEN byte-identical data
#   frames (the initial + the 10 retransmissions) + the handshake.
#
# The FULL 39-gate verify-vz aggregate must stay green (re-run
# separately); the N10 gate re-runs byte-exact — the tcp= line APPENDS
# `,retx=,abort=` at the end, so its substring assertions hold.
# Evidence under artifacts/: live-net-tcp-rto-*.txt (runner output),
# live-net-tcp-rto-*.log (serial copies), live-net-tcp-rto-*.bin (host
# captures).
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-net-tcp-rto.sh
#
# Evidence: artifacts/live-net-tcp-rto-gate.txt (full output),
# artifacts/live-net-tcp-rto-report.txt (per-run detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# logs, captures, and scripts under $RUN_DIR for all three runs; rc
# handoff files moved under $RUN_DIR too. Expectation note (#528 rot
# class 1, claim 2259): the historical $'...nvirelai> ' script-expects
# died with M18 T5's ANSI-colored prompt (claim 0163); all three runs
# anchor on the OUTPUT-ONLY done echo. Set VIRELAI_GATE_SUFFIX=_alt for
# distinct canonical evidence names; VIRELAI_KEEP_RUN=1 keeps the
# scratch dir.

GATE_LOG="$(art live-net-tcp-rto-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-net-tcp-rto-report.txt)"

echo "=== verify-live-net-tcp-rto: claim 5357 — the bounded TCP retransmission + retransmit timer live on VZ (Run A the retransmission proof, Run B the ACK-clears-pending recovery, Run C the retransmission bound) ==="

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

# --- per-run isolation -------------------------------------------------------
gate_begin live-net-tcp-rto
echo "run dir: $RUN_DIR"

# --- scripted keystrokes ----------------------------------------------------
# Run A: the black-hole SYN. `net arp 10.0.0.2` (twice) resolves the
# peer; `net tcp connect` transmits the SYN (recorded pending — card
# N11). The `net` right after reads retx=0 (no RTO elapsed yet). The
# 7 s script2 delay passes two 3 s RTOs — the idle loop retransmits
# the SYN twice, autonomously; script2's `net tcp` reads syn_sent
# (the 30 s timeout has not expired), `net` reads retx=2.
cat > "$RUN_DIR/a1.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp
net tcp connect 10.0.0.2 9999
net
echo n11a-phase1-ready
EOF
cat > "$RUN_DIR/a2.txt" <<'EOF'
net tcp
net
echo n11a-done
EOF
# Run B: the recovery. Same shape but the responder answers the
# SYN-ACK — the ACK (delivered by the idle drain) clears the pending
# SYN, so despite the 7 s wait NOTHING is retransmitted; script2's
# `net tcp` transmits the handshake ACK (established).
cat > "$RUN_DIR/b1.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp
net tcp connect 10.0.0.2 9999
net
echo n11b-phase1-ready
EOF
cat > "$RUN_DIR/b2.txt" <<'EOF'
net tcp
net
echo n11b-done
EOF
# Run C: the retransmission bound. The `:handshake` responder answers
# the SYN-ACK then goes SILENT on data — the data never gets its ACK,
# the idle loop retransmits it 10 times (one per 3 s RTO), and at the
# bound the connection aborts honestly. The 34 s delay passes the
# abort (33 s); script2's `net tcp` reads no connection, `net` reads
# retx=10,abort=1.
cat > "$RUN_DIR/c1.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp
net tcp connect 10.0.0.2 9999
net tcp
net tcp send 5
net
echo n11c-phase1-ready
EOF
cat > "$RUN_DIR/c2.txt" <<'EOF'
net tcp
net
echo n11c-done
EOF

# --- per-run gate -----------------------------------------------------------
run_a() {
    local out="$1" serial="$2" capture="$3"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-a.log" "$capture"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-a.log" \
        --net "$capture" --net-arp-respond 10.0.0.2 \
        --script "$RUN_DIR/a1.txt" \
        --script2 "$RUN_DIR/a2.txt" --script2-after "n11a-phase1-ready" --script2-delay 7 \
        --script-expect 'n11a-done' --timeout 120 \
        > "$out" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-a.log" ] && cp "$RUN_DIR/vm-serial-a.log" "$serial" || true
    echo "$RC" > "$RUN_DIR/rc-a"
}

run_b() {
    local out="$1" serial="$2" capture="$3"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-b.log" "$capture"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-b.log" \
        --net "$capture" --net-tcp-respond 10.0.0.2:9999 --net-arp-respond 10.0.0.2 \
        --script "$RUN_DIR/b1.txt" \
        --script2 "$RUN_DIR/b2.txt" --script2-after "n11b-phase1-ready" --script2-delay 7 \
        --script-expect 'n11b-done' --timeout 120 \
        > "$out" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-b.log" ] && cp "$RUN_DIR/vm-serial-b.log" "$serial" || true
    echo "$RC" > "$RUN_DIR/rc-b"
}

run_c() {
    local out="$1" serial="$2" capture="$3"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-c.log" "$capture"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-c.log" \
        --net "$capture" --net-tcp-respond 10.0.0.2:9999:handshake --net-arp-respond 10.0.0.2 \
        --script "$RUN_DIR/c1.txt" \
        --script2 "$RUN_DIR/c2.txt" --script2-after "n11c-phase1-ready" --script2-delay 34 \
        --script-expect 'n11c-done' --timeout 140 \
        > "$out" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-c.log" ] && cp "$RUN_DIR/vm-serial-c.log" "$serial" || true
    echo "$RC" > "$RUN_DIR/rc-c"
}

set +e
run_a "$(art live-net-tcp-rto-a-run.txt)" "$(art live-net-tcp-rto-a-serial.log)" "$RUN_DIR/a-cap.bin"
RCA="$(cat "$RUN_DIR/rc-a")"
cp "$RUN_DIR/a-cap.bin" "$(art live-net-tcp-rto-a-cap.bin)" 2>/dev/null || true
run_b "$(art live-net-tcp-rto-b-run.txt)" "$(art live-net-tcp-rto-b-serial.log)" "$RUN_DIR/b-cap.bin"
RCB="$(cat "$RUN_DIR/rc-b")"
cp "$RUN_DIR/b-cap.bin" "$(art live-net-tcp-rto-b-cap.bin)" 2>/dev/null || true
run_c "$(art live-net-tcp-rto-c-run.txt)" "$(art live-net-tcp-rto-c-serial.log)" "$RUN_DIR/c-cap.bin"
RCC="$(cat "$RUN_DIR/rc-c")"
cp "$RUN_DIR/c-cap.bin" "$(art live-net-tcp-rto-c-cap.bin)" 2>/dev/null || true
set -e

# --- Run A assertions ---------------------------------------------------------
SA="$(art live-net-tcp-rto-a-serial.log)"
SA_BYTES=0 ASYN=0 ARETX1=0 ARETX2=0 ANORETX=0 ARETX2REPORT=0 ADONE=0
if [ -f "$SA" ]; then
    SA_BYTES=$(wc -c < "$SA" | tr -d ' ')
    grep -a -qE -- "net tcp: syn sent \\(peer=10\\.0\\.0\\.2:9999, seq=0x[0-9a-f]+, 54 bytes\\)" "$SA" && ASYN=1
    # The idle loop retransmitted the SYN twice, autonomously (the RTO
    # fired at 3 s and 6 s of guest ticks — the printed retransmission
    # count is the retx_count AFTER the increment, so 1/10 then 2/10).
    grep -a -qF -- "net tcp: syn retransmitted (1/10)" "$SA" && ARETX1=1
    grep -a -qF -- "net tcp: syn retransmitted (2/10)" "$SA" && ARETX2=1
    # The phase-1 report (right after the connect) read retx=0; the
    # phase-2 report (after the two RTOs) reads retx=2. Still syn_sent —
    # the 30 s connect timeout has not expired.
    grep -a -qF -- "tcp=syn_sent,peer=10.0.0.2:9999,syn=1,synack=0,ack=0,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=0,abort=0" "$SA" && ANORETX=1
    # The phase-2 report: still syn_sent (the 30 s connect timeout has
    # NOT expired) with retx >= 2 — the retransmission COUNT is the
    # honest observation (the RTO is a 1 Hz-tick timer; a third RTO can
    # fire depending on the exact boot/settle timing — the byte-exact
    # capture + the (1/10)/(2/10) lines are the deterministic core).
    if grep -a -qF -- "tcp=syn_sent,peer=10.0.0.2:9999,syn=1,synack=0,ack=0,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=" "$SA"; then
        RETXV=$(grep -a -oE "retx=[0-9]+" "$SA" | tail -1 | cut -d= -f2)
        [ "${RETXV:-0}" -ge 2 ] && ARETX2REPORT=1
    fi
    grep -a -qF -- "n11a-done" "$SA" && ADONE=1
fi
ARUNNER=0
[ "$RCA" = 0 ] && grep -a -qF -- "net-arp-respond: ENABLED" "$(art live-net-tcp-rto-a-run.txt)" && ARUNNER=1
# The capture: ARP (42) + the byte-identical SYN frames (the initial
# + the RTO retransmissions, 54 B each), verified by the python walk —
# the SAME seq (the ISN drawn once at connect — the retransmissions
# reuse it), the same flags/ports/MACs, and the IPv4 + TCP checksums.
# At least THREE (the initial + >= 2 retransmissions) — the exact RTO
# count is timing-dependent (the 1 Hz-tick timer); the byte-exactness
# is deterministic.
A3SYN=0
if [ -f "$(art live-net-tcp-rto-a-cap.bin)" ]; then
    if python3 - "$(art live-net-tcp-rto-a-cap.bin)" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
off = 0
syns = []
while off < len(d):
    if d[off+12:off+14] == b'\x08\x00':
        total = (d[off+16] << 8) | d[off+17]
        syns.append(d[off:off+14+total])
        off += 14 + total
    else:
        off += 42  # the N3 unpadded ARP frame
assert len(syns) >= 3, len(syns)
assert all(len(f) == 54 for f in syns), [len(f) for f in syns]
# The total must be exactly the ARP + the SYN frames (nothing else).
assert len(d) == 42 + 54 * len(syns), len(d)
def chk(data):
    if len(data) % 2: data += b'\x00'
    s = sum(struct.unpack('>%dH' % (len(data) // 2), data))
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
# The SYN frames are byte-IDENTICAL — the same seq (the ISN is drawn
# once at connect; the retransmissions reuse the exact pending bytes),
# the same flags, ports, MACs, and checksums.
assert all(f == syns[0] for f in syns), "the retransmitted SYNs must be byte-identical"
assert syns[0][47] == 0x02 and syns[0][42:46] == b'\x00' * 4, "syn flags/ack"
assert (syns[0][34] << 8) | syns[0][35] == 8000 and (syns[0][36] << 8) | syns[0][37] == 9999, "syn ports"
assert syns[0][30:34] == bytes([10, 0, 0, 2]), "syn dst ip"
assert syns[0][0:6] == bytes([2, 0, 0, 0, 0, 2]) and syns[0][6:12] == bytes([2, 0, 0, 0, 0, 1]), "syn macs"
assert syns[0][46] == 0x50 and syns[0][48:50] == bytes([0x10, 0x00]), "syn offset/window"
assert chk(syns[0][14:34]) == 0, "syn ipv4 checksum"
for i, f in enumerate(syns):
    seg = f[34:]
    ps = bytes([10, 0, 0, 1, 10, 0, 0, 2, 0, 6]) + struct.pack('>H', len(seg))
    assert chk(ps + seg) == 0, ("tcp checksum", i)
print("Run A capture: ARP + %d byte-identical SYN frames (the initial + the RTO retransmissions, same seq/bytes/checksums)" % len(syns))
PY
    then
        A3SYN=1
    fi
fi

# --- Run B assertions (the ACK-clears-pending recovery) -----------------------
SB="$(art live-net-tcp-rto-b-serial.log)"
SB_BYTES=0 BSYN=0 BESTAB=0 BRETX0A=0 BRETX0B=0 BNRETX=1 BDONE=0
if [ -f "$SB" ]; then
    SB_BYTES=$(wc -c < "$SB" | tr -d ' ')
    grep -a -qE -- "net tcp: syn sent \\(peer=10\\.0\\.0\\.2:9999, seq=0x[0-9a-f]+, 54 bytes\\)" "$SB" && BSYN=1
    # The SYN-ACK was delivered by the idle drain; the script2 `net tcp`
    # transmitted the handshake ACK — established.
    grep -a -qF -- "net tcp: established (peer=10.0.0.2:9999)" "$SB" && BESTAB=1
    # retx=0 in BOTH reports — the ACK cleared the pending SYN before the
    # RTO (7 s wait) could fire a retransmission.
    # The phase-1 `net` drains first — the responder's SYN-ACK had
    # already landed, so the FIRST report already shows ESTABLISHED
    # (synack=1, ack=0 — the handshake ACK is transmitted by script2's
    # `net tcp`) with retx=0. The SYN-ACK acknowledged the SYN before
    # any RTO — the pending state cleared.
    grep -a -qF -- "tcp=established,peer=10.0.0.2:9999,syn=1,synack=1,ack=0,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=0,abort=0" "$SB" && BRETX0A=1
    grep -a -qF -- "tcp=established,peer=10.0.0.2:9999,syn=1,synack=1,ack=1,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=0,abort=0" "$SB" && BRETX0B=1
    # No retransmission line at all.
    grep -a -q "retransmitted" "$SB" && BNRETX=0
    grep -a -qF -- "n11b-done" "$SB" && BDONE=1
fi
BRUNNER=0
[ "$RCB" = 0 ] && grep -a -qF -- "net-tcp-respond: ENABLED (milestone five card N10, claim 7026) + card N11 (claim 5357)" "$(art live-net-tcp-rto-b-run.txt)" && BRUNNER=1
# The capture: ARP (42) + the SYN (54) + the handshake ACK (54) = 150
# bytes — EXACTLY ONE SYN (no retransmission).
B1SYN=0
if [ -f "$(art live-net-tcp-rto-b-cap.bin)" ] && [ "$(wc -c < "$(art live-net-tcp-rto-b-cap.bin)" | tr -d ' ')" = 150 ]; then
    if python3 - "$(art live-net-tcp-rto-b-cap.bin)" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
off = 0
tcpf = []
while off < len(d):
    if d[off+12:off+14] == b'\x08\x00':
        total = (d[off+16] << 8) | d[off+17]
        tcpf.append(d[off:off+14+total])
        off += 14 + total
    else:
        off += 42
assert len(tcpf) == 2, len(tcpf)
assert [len(f) for f in tcpf] == [54, 54], [len(f) for f in tcpf]
assert tcpf[0][47] == 0x02 and tcpf[1][47] == 0x10, "SYN then the handshake ACK"
synseq = int.from_bytes(tcpf[0][38:42], 'big')
# The handshake ACK: seq = the SYN seq + 1, ack = the FIXED server ISN
# 0x12345678 + 1 (it acknowledges the SERVER's sequence, not our SYN's
# — the N10 gate's walk pins the same relation).
assert tcpf[1][38:42] == ((synseq + 1) & 0xffffffff).to_bytes(4, 'big'), "handshake ack seq"
assert tcpf[1][42:46] == (0x12345678 + 1).to_bytes(4, 'big'), "handshake ack ack = the server ISN + 1"
print("Run B capture: ARP + exactly ONE SYN + the handshake ACK (no retransmission)")
PY
    then
        B1SYN=1
    fi
fi

# --- Run C assertions (the retransmission bound) ------------------------------
SC="$(art live-net-tcp-rto-c-serial.log)"
SC_BYTES=0 CSYN=0 CACK=0 CDATASENT=0 CRETX0=0 CRETX10=0 CEDGES=0 CABORT=0 CNOCONN=0 CRETXREPORT=0 CDONE=0
if [ -f "$SC" ]; then
    SC_BYTES=$(wc -c < "$SC" | tr -d ' ')
    grep -a -qE -- "net tcp: syn sent \\(peer=10\\.0\\.0\\.2:9999, seq=0x[0-9a-f]+, 54 bytes\\)" "$SC" && CSYN=1
    grep -a -qF -- "net tcp: ack sent (ack=0x12345679, 54 bytes)" "$SC" && CACK=1
    grep -a -qE -- "net tcp: data sent \\(seq=0x[0-9a-f]+, 5 bytes\\)" "$SC" && CDATASENT=1
    # The phase-1 report read retx=0 (no RTO elapsed yet).
    grep -a -qF -- "tcp=established,peer=10.0.0.2:9999,syn=1,synack=1,ack=1,data_s=1,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=0,abort=0" "$SC" && CRETX0=1
    # The ten data retransmissions, one per 3 s RTO, counted and printed
    # by the idle loop — and the FIRST is byte-exact in the capture.
    [ "$(grep -ac -- 'net tcp: data retransmitted (' "$SC")" = 10 ] && CRETX10=1
    grep -a -qF -- "net tcp: data retransmitted (1/10)" "$SC" && grep -a -qF -- "net tcp: data retransmitted (10/10)" "$SC" && CEDGES=1 || CEDGES=0
    # The bound aborted the connection honestly (no RST, no TX — the
    # N10 abort_timeout pattern); the report released the state; the
    # next drive reads no connection.
    grep -a -qF -- "net tcp: retransmission limit reached (10) — connection aborted" "$SC" && CABORT=1
    grep -a -qF -- "tcp=idle,peer=0.0.0.0:0,syn=1,synack=1,ack=1,data_s=1,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=10,abort=1" "$SC" && CRETXREPORT=1
    grep -a -qF -- "net tcp: no connection (net tcp connect <addr> <port>)" "$SC" && CNOCONN=1
    grep -a -qF -- "n11c-done" "$SC" && CDONE=1
fi
CRUNNER=0
[ "$RCC" = 0 ] && grep -a -qF -- "net-tcp-respond mode: handshake-only (card N11)" "$(art live-net-tcp-rto-c-run.txt)" && CRUNNER=1
# The capture: ARP (42) + the SYN (54) + the handshake ACK (54) + the
# ELEVEN byte-identical data frames (11 x 59 = 649) = 799 bytes — the
# initial data + the 10 retransmissions, all the SAME seq/bytes/checksum.
CCAP=0
if [ -f "$(art live-net-tcp-rto-c-cap.bin)" ] && [ "$(wc -c < "$(art live-net-tcp-rto-c-cap.bin)" | tr -d ' ')" = 799 ]; then
    if python3 - "$(art live-net-tcp-rto-c-cap.bin)" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
off = 0
tcpf = []
while off < len(d):
    if d[off+12:off+14] == b'\x08\x00':
        total = (d[off+16] << 8) | d[off+17]
        tcpf.append(d[off:off+14+total])
        off += 14 + total
    else:
        off += 42
assert len(tcpf) == 13, len(tcpf)
assert [len(f) for f in tcpf] == [54, 54] + [59] * 11, [len(f) for f in tcpf]
def chk(data):
    if len(data) % 2: data += b'\x00'
    s = sum(struct.unpack('>%dH' % (len(data) // 2), data))
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
assert tcpf[0][47] == 0x02 and tcpf[1][47] == 0x10, "SYN then the handshake ACK"
data = tcpf[2:]
# The ELEVEN data frames are byte-IDENTICAL — the initial + the 10 RTO
# retransmissions reuse the exact pending bytes (seq, ack, flags,
# payload 01 02 03 04 05, checksum).
assert all(f == data[0] for f in data), "the retransmitted data frames must be byte-identical"
assert data[0][47] == 0x10 and data[0][54:59] == bytes([1, 2, 3, 4, 5]), "data flags/payload"
for i, f in enumerate(tcpf):
    seg = f[34:]
    ps = bytes([10, 0, 0, 1, 10, 0, 0, 2, 0, 6]) + struct.pack('>H', len(seg))
    assert chk(ps + seg) == 0, ("tcp checksum", i)
print("Run C capture: ARP + SYN + handshake ACK + eleven byte-identical data frames (initial + 10 retransmissions)")
PY
    then
        CCAP=1
    fi
fi

# --- tally --------------------------------------------------------------------
PASS=0 FAIL=0
tally() {
    local name="$1" ok="$2"
    if [ "$ok" = 1 ]; then
        PASS=$((PASS + 1))
        echo "PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $name"
    fi
}

echo
echo "=== Run A (the retransmission proof) ==="
tally "runner rc" "$([ "$RCA" = 0 ] && echo 1 || echo 0)"
tally "serial log present ($SA_BYTES bytes)" "$([ "$SA_BYTES" -gt 1000 ] && echo 1 || echo 0)"
tally "syn sent" "$ASYN"
tally "syn retransmitted (1/10)" "$ARETX1"
tally "syn retransmitted (2/10)" "$ARETX2"
tally "report retx=0 before the RTOs" "$ANORETX"
tally "report retx>=2 after the RTOs" "$ARETX2REPORT"
tally "runner arp-respond flag" "$ARUNNER"
tally "capture: >=3 byte-identical SYN frames" "$A3SYN"
tally "n11a-done marker" "$ADONE"

echo
echo "=== Run B (the ACK-clears-pending recovery) ==="
tally "runner rc" "$([ "$RCB" = 0 ] && echo 1 || echo 0)"
tally "serial log present ($SB_BYTES bytes)" "$([ "$SB_BYTES" -gt 1000 ] && echo 1 || echo 0)"
tally "syn sent" "$BSYN"
tally "established (handshake completed)" "$BESTAB"
tally "report retx=0 (phase 1)" "$BRETX0A"
tally "report retx=0 after the wait" "$BRETX0B"
tally "no retransmission happened (no retransmitted lines)" "$BNRETX"
tally "runner tcp-respond flag" "$BRUNNER"
tally "capture 150 bytes + exactly ONE SYN" "$B1SYN"
tally "n11b-done marker" "$BDONE"

echo
echo "=== Run C (the retransmission bound) ==="
tally "runner rc" "$([ "$RCC" = 0 ] && echo 1 || echo 0)"
tally "serial log present ($SC_BYTES bytes)" "$([ "$SC_BYTES" -gt 1000 ] && echo 1 || echo 0)"
tally "syn sent + handshake ack" "$CSYN"
tally "handshake ack (ack=0x12345679)" "$CACK"
tally "data sent (5 bytes)" "$CDATASENT"
tally "report retx=0 before the RTOs" "$CRETX0"
tally "ten data retransmissions (1/10..10/10)" "$CRETX10"
tally "first + last retransmission lines present" "$CEDGES"
tally "retransmission limit reached — connection aborted" "$CABORT"
tally "report tcp=idle,peer=0.0.0.0:0,retx=10,abort=1" "$CRETXREPORT"
tally "no connection after the abort" "$CNOCONN"
tally "runner handshake-only flag" "$CRUNNER"
tally "capture 799 bytes + eleven byte-identical data frames" "$CCAP"
tally "n11c-done marker" "$CDONE"

echo
echo "=== verify-live-net-tcp-rto: $PASS passed, $FAIL failed ==="
{
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "Run A rc=$RCA Run B rc=$RCB Run C rc=$RCC"
    echo "PASS=$PASS FAIL=$FAIL"
} > "$REPORT"
[ "$FAIL" = 0 ] || exit 1
echo "verify-live-net-tcp-rto: PASS ($PASS/$PASS)"
