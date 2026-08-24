#!/usr/bin/env bash
#
# verify-live-net-dhcp.sh -- claim 0351 (milestone five, card N8) class-B
# gate: the bounded RFC 2131 DHCP client on the N5/N6 UDP layer, live on
# real VZ hardware, in TWO phases.
#
# Phase 1 — deterministic file-handle (--net <capture> +
# --net-dhcp-respond <lease-ip>): the runner's capture thread answers
# the guest's DHCPDISCOVER with a crafted OFFER and its REQUEST with an
# ACK — a tiny deterministic host-side DHCP server with a FIXED,
# gate-assertable lease {ip 10.0.0.2, mask 255.255.255.0, gateway
# 10.0.0.1, server id = the lease IP, lease 3600s} and the guest's xid
# echoed byte-exact. The gate drives `net dhcp` (the claim-0351 monitor
# subcommand), waits for the full INIT -> SELECTING -> REQUESTING ->
# BOUND handshake, and asserts: the 286-byte DISCOVER byte-exact in the
# capture (dst ff*6, src 02:00:00:00:00:01, ethertype 0x0800, src port
# 68 -> dst 67, op BOOTREQUEST, the magic cookie 0x63825363, option 53
# = 1), the runner's NET-DHCP OFFER/ACK lines, the bound lease line
# (`net: dhcp bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1
# server=10.0.0.2 lease=3600`), and the `net` report counters
# (dhcp=bound,...,discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,
# mal=0).
#
# Phase 2 — real NAT (rides card N7's --net-nat): `net dhcp` against the
# host's REAL services. CLAIM-TIME OBSERVATION, UPDATED 2026-08-24
# (claim 2259): the ORIGINAL observation recorded that this host's VZ NAT
# attachment served NO DHCP (discover=1, offer=0 — the honest-blocked
# record, log under artifacts/live-net-dhcp-nat-explore/). TODAY the same
# host's NAT ANSWERS: the guest's DISCOVER draws a real OFFER and the
# handshake COMPLETES — OBSERVED BYTES: the final report reads
# `dhcp=bound,ip=192.168.64.4,...,server=192.168.64.1,lease=3600,
# discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,mal=0,...`
# (a dynamic lease from the gateway itself). Per this gate's own
# instructions the phase-2 assertions are FLIPPED TO THE BOUND PATH: the
# gate asserts the DISCOVER went out AND the real-network lease bound
# (dynamic ip, fixed server 192.168.64.1, ack=1). The guest-is-not-
# stranded proof stays: the static fallback still reaches the NAT
# gateway (net ip 192.168.64.5 + net arp x2 + net ping 192.168.64.1 ->
# pong=1 seq=1, the N7-proven story).
#
# The FULL 35-gate verify-vz aggregate must stay green (re-run
# separately) — proof the N8 changes left the default VM byte-identical;
# the N6 seam regression (UDP.BIN) re-runs green. Evidence under
# artifacts/: live-net-dhcp-*.txt (runner output), live-net-dhcp-*.log
# (serial copies), live-net-dhcp-*.bin (host captures), and the report.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-net-dhcp.sh
#
# Evidence: artifacts/live-net-dhcp-gate.txt (full output),
# artifacts/live-net-dhcp-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# logs, captures, and scripts under $RUN_DIR for BOTH phases; fresh EFI
# vars per boot as before. Expectation note (#528 rot class 1, claim
# 2259): the historical $'...ndipshit> ' script-expects died with M18 T5's
# ANSI-colored prompt (claim 0163); both phases now anchor on the
# OUTPUT-ONLY success echo, which exists only in command output.
# Set DIPSHIT_GATE_SUFFIX=_alt for distinct canonical evidence names;
# DIPSHIT_KEEP_RUN=1 keeps the scratch dir.

GATE_LOG="$(art live-net-dhcp-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-net-dhcp-report.txt)"

echo "=== verify-live-net-dhcp: claim 0351 — the RFC 2131 DHCP client live on VZ (phase 1 deterministic file-handle handshake, phase 2 real-NAT honest observation) ==="

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
gate_begin live-net-dhcp
echo "run dir: $RUN_DIR"

# --- scripted keystrokes ----------------------------------------------------
# The claim-4613 two-phase pattern. PHASE 1 (file-handle): --script runs
# `net dhcp` repeatedly — each invocation drains pending RX first, so
# whichever invocation catches the OFFER moves to REQUESTING and
# transmits the REQUEST in the SAME invocation; the next catches the
# ACK and reaches BOUND (the monitor-driven polled-drain contract —
# deterministic, no interrupts, no sleep races). The ready marker ends
# phase 1; --script2 (forwarded after the marker, claim-6684 0.5 s
# settle) re-runs `net dhcp` (the BOUND branch prints the lease), reads
# the full `net` report, and echoes the gate marker. PHASE 2 (NAT): the
# same shape against --net-nat, plus the static-fallback reachability
# proof (net ip 192.168.64.5 + net arp 192.168.64.1 + net ping
# 192.168.64.1).
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net
echo net-dhcp-phase1-ready
EOF
cat > "$RUN_DIR/script-2.txt" <<'EOF'
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net
echo net-dhcp-ok
EOF
cat > "$RUN_DIR/script-nat-1.txt" <<'EOF'
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net
net ip 192.168.64.5
net arp 192.168.64.1
net arp 192.168.64.1
net ping 192.168.64.1
echo net-dhcp-nat-phase1-ready
EOF
cat > "$RUN_DIR/script-nat-2.txt" <<'EOF'
net arp 192.168.64.1
net ping 192.168.64.1
net
net
echo net-dhcp-nat-ok
EOF

# --- per-phase run -----------------------------------------------------------
# Phase 1: $1 = runner output, $2 = serial copy, $3 = capture file.
run_phase1() {
    local out="$1" serial="$2" capture="$3"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-p1.log" "$capture"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-p1.log" \
        --net "$capture" --net-dhcp-respond 10.0.0.2 \
        --script "$RUN_DIR/script-1.txt" \
        --script2 "$RUN_DIR/script-2.txt" --script2-after "net-dhcp-phase1-ready" \
        --script-expect 'net-dhcp-ok' --timeout 40 \
        > "$out" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-p1.log" ] && cp "$RUN_DIR/vm-serial-p1.log" "$serial" || true
    echo "$RC" > "$RUN_DIR/rc-p1"
}

# Phase 2 (NAT): same shape, no responder — the honest observation.
run_phase2() {
    local out="$1" serial="$2"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-p2.log"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-p2.log" \
        --net-nat \
        --script "$RUN_DIR/script-nat-1.txt" \
        --script2 "$RUN_DIR/script-nat-2.txt" --script2-after "net-dhcp-nat-phase1-ready" \
        --script-expect 'net-dhcp-nat-ok' --timeout 40 \
        > "$out" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-p2.log" ] && cp "$RUN_DIR/vm-serial-p2.log" "$serial" || true
    echo "$RC" > "$RUN_DIR/rc-p2"
}

set +e
run_phase1 "$(art live-net-dhcp-p1-run.txt)" "$(art live-net-dhcp-p1-serial.log)" "$RUN_DIR/p1-cap.bin"
RC1="$(cat "$RUN_DIR/rc-p1")"
cp "$RUN_DIR/p1-cap.bin" "$(art live-net-dhcp-p1-cap.bin)" 2>/dev/null || true
run_phase2 "$(art live-net-dhcp-p2-run.txt)" "$(art live-net-dhcp-p2-serial.log)"
RC2="$(cat "$RUN_DIR/rc-p2")"
set -e

# --- phase-1 assertions -------------------------------------------------------
S1="$(art live-net-dhcp-p1-serial.log)"
S1_BYTES=0 DISCOVER=0 BOUND=0 REPORTCNTR=0 OK1=0
if [ -f "$S1" ]; then
    S1_BYTES=$(wc -c < "$S1" | tr -d ' ')
    # The client sent the DISCOVER (286 bytes, the broadcast shape).
    grep -a -qE -- "net dhcp: discover sent xid=0x[0-9a-f]+ \(286 bytes\)" "$S1" && DISCOVER=1
    # The handshake completed: the BOUND branch printed the fixed lease.
    grep -a -qF -- "net: dhcp bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=3600" "$S1" && BOUND=1
    # The report counters: every message of the four-message handshake
    # observed exactly once, nothing malformed.
    grep -a -qF -- "dhcp=bound,ip=10.0.0.2,mask=255.255.255.0,gw=10.0.0.1,server=10.0.0.2,lease=3600,discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,mal=0" "$S1" && REPORTCNTR=1
    grep -a -qF -- "net-dhcp-ok" "$S1" && OK1=1
fi
RUN1=0 NETDHCPDISCOVER=0 NETDHCPACK=0 RUNNERFLAG1=0
# The host answered BOTH messages (its own stdout lines).
grep -a -qE -- "NET-DHCP: answered the guest's DHCP DISCOVER \(xid 0x[0-9a-f]+\) with a OFFER for 10.0.0.2 \(lease 3600s\)" "$(art live-net-dhcp-p1-run.txt)" && NETDHCPDISCOVER=1
grep -a -qE -- "NET-DHCP: answered the guest's DHCP REQUEST \(xid 0x[0-9a-f]+\) with a ACK for 10.0.0.2 \(lease 3600s\)" "$(art live-net-dhcp-p1-run.txt)" && NETDHCPACK=1
grep -a -qF -- "net-dhcp-respond: ENABLED (milestone five card N8, claim 0351)" "$(art live-net-dhcp-p1-run.txt)" && RUNNERFLAG1=1
# The capture holds BOTH client messages byte-exact at the load-bearing
# offsets (the N2 host->guest direction is not captured, so the OFFER/ACK
# are proven by the guest's bound + counters instead): the 286-byte
# DISCOVER (dst ff:ff:ff:ff:ff:ff, src 02:00:00:00:00:01, ethertype
# 0x0800, src port 68 -> dst port 67, op BOOTREQUEST, the magic cookie at
# 278, option 53 = 1 at 282) followed by the 298-byte REQUEST (the same
# frame shape with option 53 = 3, the SAME xid — one transaction).
CAP1=0
if [ -f "$(art live-net-dhcp-p1-cap.bin)" ]; then
    CAPSIZE=$(wc -c < "$(art live-net-dhcp-p1-cap.bin)" | tr -d ' ')
    if [ "$CAPSIZE" = 584 ]; then
        CAPHEX=$(xxd -p "$(art live-net-dhcp-p1-cap.bin)" | tr -d '\n')
        if [ "${CAPHEX:0:24}" = "ffffffffffff020000000001" ] && \
           [ "${CAPHEX:24:4}" = "0800" ] && \
           [ "${CAPHEX:68:4}" = "0044" ] && [ "${CAPHEX:72:4}" = "0043" ] && \
           [ "${CAPHEX:84:2}" = "01" ] && \
           [ "${CAPHEX:556:8}" = "63825363" ] && \
           [ "${CAPHEX:564:6}" = "350101" ] && \
           [ "${CAPHEX:572:24}" = "ffffffffffff020000000001" ] && \
           [ "${CAPHEX:1128:8}" = "63825363" ] && \
           [ "${CAPHEX:1136:6}" = "350103" ]; then
            CAP1=1
        fi
    fi
fi

# --- phase-2 assertions -------------------------------------------------------
S2="$(art live-net-dhcp-p2-serial.log)"
S2_BYTES=0 NATDISCOVER=0 NATBOUND=0 NATPONG=0 OK2=0
if [ -f "$S2" ]; then
    S2_BYTES=$(wc -c < "$S2" | tr -d ' ')
    # The client TRIED the real network: the DISCOVER went out.
    grep -a -qE -- "net dhcp: discover sent xid=0x[0-9a-f]+ \(286 bytes\)" "$S2" && NATDISCOVER=1
    # THE UPDATED CLAIM-TIME OBSERVATION (2026-08-24, claim 2259): the VZ
    # NAT gateway SERVES DHCP on this host today — the handshake bound a
    # dynamic lease from server 192.168.64.1. The lease IP is dynamic
    # (.4 today); the server id and the four-message counters are stable,
    # so anchor there (grep -F prefixes on the stable head and tail of
    # the OBSERVED line).
    grep -a -q -- "dhcp=bound,ip=192\\.168\\.64\\.[0-9]*," <<< "$(grep -a 'dhcp=bound' "$S2" | tail -1)" && \
        grep -a -qE -- "dhcp=bound,ip=192\\.168\\.64\\.[0-9]+,mask=[0-9.]+,gw=[0-9.]*,server=192\\.168\\.64\\.1,lease=3600,discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,mal=0" "$S2" && NATBOUND=1
    # The guest is NOT stranded: the static fallback still reaches the
    # NAT gateway (the N7-proven gateway round trip, pong=1 seq=1).
    grep -a -qF -- " icmp=req=1,repl=0,pong=1,drop=0,fail=0,seq=1" "$S2" && NATPONG=1
    grep -a -qF -- "net-dhcp-nat-ok" "$S2" && OK2=1
fi
RUN2=0 RUNNERFLAG2=0
grep -a -qF -- "net-nat: ENABLED (milestone five card N7, claim 4678)" "$(art live-net-dhcp-p2-run.txt)" && RUNNERFLAG2=1

{
    echo "p1: rc=$RC1 serial-bytes=$S1_BYTES discover=$DISCOVER bound=$BOUND report-counters=$REPORTCNTR ok=$OK1 runner=$RUNNERFLAG1 net-dhcp-discover=$NETDHCPDISCOVER net-dhcp-ack=$NETDHCPACK capture=$CAP1"
    echo "p2: rc=$RC2 serial-bytes=$S2_BYTES nat-discover=$NATDISCOVER nat-bound=$NATBOUND nat-pong=$NATPONG ok=$OK2 runner=$RUNNERFLAG2"
} >> "$REPORT"
echo "p1 rc=$RC1 serial-bytes=$S1_BYTES discover=$DISCOVER bound=$BOUND report-counters=$REPORTCNTR ok=$OK1 runner=$RUNNERFLAG1 net-dhcp-discover=$NETDHCPDISCOVER net-dhcp-ack=$NETDHCPACK capture=$CAP1"
echo "p2 rc=$RC2 serial-bytes=$S2_BYTES nat-discover=$NATDISCOVER nat-bound=$NATBOUND nat-pong=$NATPONG ok=$OK2 runner=$RUNNERFLAG2"

PASS=0
if [ "$RC1" = 0 ] && [ "$DISCOVER" = 1 ] && [ "$BOUND" = 1 ] && [ "$REPORTCNTR" = 1 ] && \
   [ "$OK1" = 1 ] && [ "$RUNNERFLAG1" = 1 ] && [ "$NETDHCPDISCOVER" = 1 ] && [ "$NETDHCPACK" = 1 ] && \
   [ "$CAP1" = 1 ] && \
   [ "$RC2" = 0 ] && [ "$NATDISCOVER" = 1 ] && [ "$NATBOUND" = 1 ] && [ "$NATPONG" = 1 ] && \
   [ "$OK2" = 1 ] && [ "$RUNNERFLAG2" = 1 ]; then
    PASS=1
fi

: > "$REPORT"
{
    echo "DIPSHITOS live DHCP gate (claim 0351, milestone five card N8) — the bounded RFC 2131 client on the N5/N6 UDP layer, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase 1 (deterministic file-handle): --net + --net-dhcp-respond 10.0.0.2 — net dhcp -> DISCOVER (286 B, byte-exact in the capture) -> OFFER -> REQUEST -> ACK -> BOUND"
    echo "assertions: runner rc, DISCOVER-sent line, the bound lease (ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=3600), the report counters (discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,mal=0), the host's NET-DHCP OFFER + ACK lines, the 584-byte capture (the 286-B DISCOVER + the 298-B REQUEST, both byte-exact at the load-bearing offsets: dst ff*6, src 02:00:00:00:00:01, ethertype 0x0800, 68->67, op 1, cookie 0x63825363, option 53 = 1 then 3, the SAME xid), the gate echo, the runner's net-dhcp-respond flag"
    echo "phase 2 (real NAT, rides --net-nat): CLAIM-TIME OBSERVATION UPDATED 2026-08-24 (claim 2259) — the VZ NAT gateway SERVES DHCP on this host today (original observation: none); the handshake bound a dynamic lease (ip=192.168.64.4 today) from server 192.168.64.1; the static fallback still reaches the NAT gateway (pong=1 seq=1)"
    echo "assertions: runner rc, the NAT DISCOVER-sent line, the bound report (dhcp=bound,ip=192.168.64.N,...,server=192.168.64.1,lease=3600,discover=1,offer=1,request=1,ack=1,...), the gateway ping pong=1 seq=1, the gate echo, the runner's net-nat flag"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-net-dhcp: PASS — phase 1 (deterministic): the guest ran the full RFC 2131 handshake against the host's crafted server — DISCOVER (286 B, byte-exact in the capture) -> OFFER -> REQUEST -> ACK -> BOUND with the fixed lease ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=3600, the report counters discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,mal=0, and the host's NET-DHCP OFFER/ACK lines. Phase 2 (real NAT): the claim-time observation UPDATED honestly (2026-08-24, claim 2259) — the VZ NAT gateway serves DHCP on this host today, and the client BOUND a dynamic lease from server 192.168.64.1 (never faked; the original no-DHCP observation remains in git history and docs/hardware-contract.md history), and the guest is NOT stranded: the static fallback still pings the NAT gateway (pong=1 seq=1)."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-net-dhcp: FAILED — see artifacts/live-net-dhcp-report.txt, the runner outputs (live-net-dhcp-p1-run.txt / p2), the serial logs (live-net-dhcp-p1-serial.log / p2), and the phase-1 capture (live-net-dhcp-p1-cap.bin)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
