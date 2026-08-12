#!/usr/bin/env bash
#
# verify-live-net-nat.sh -- claim 4678 (milestone five, card N7) class-B
# gate: outbound connectivity through VZNATNetworkDeviceAttachment on real
# VZ hardware.
#
# Mechanism: the runner's new --net-nat flag (card N7) attaches one
# VZVirtioNetworkDeviceConfiguration with a VZNATNetworkDeviceAttachment
# instead of the file-handle attachment — the host serves as the guest's
# router and performs NAT for accesses to outside networks. The guest
# DRIVER is unchanged (N1–N6); this gate drives the EXISTING monitor
# surface (net ip / net arp / net ping from claims N3/N4) against the
# NAT gateway and asserts GUEST-OBSERVED COUNTERS.
#
# Gate-shape change (the card's one deliberate engineering surprise,
# documented in the prompt): the byte-exact capture-file evidence does
# NOT apply through NAT — the host translates the frames, that is the
# point of NAT; the runner never sees guest bytes. So this gate asserts
# the guest's OWN report lines instead of capture bytes.
#
# Claim-time observations (pinned in docs/hardware-contract.md, saved
# logs under artifacts/live-net-nat-explore/):
#   * MAC under NAT: the NAT attachment HONORS the configured
#     locally-administered MAC — the guest reports
#     `net: mac=02:00:00:00:00:01 source=feature` (identical to the
#     file-handle path).
#   * Subnet/gateway: VZ exposes no NAT prefix API; observed on the
#     first live run — 192.168.64.0/24, gateway 192.168.64.1 (the
#     guest is statically addressed 192.168.64.5).
#   * The NAT gateway ANSWERS ARP for 192.168.64.1 (the guest learns
#     the gateway MAC: `net arp: 192.168.64.1 is at …`) and ANSWERS
#     ICMP echo (net ping 192.168.64.1 -> pong=1 with seq=1) — the
#     deterministic proof, NO internet dependency.
#   * The NAT router also SENDS IPv6 multicast to the guest at boot
#     (router advertisements — the guest's first rx-obs shows dst
#     33:33:00:00…); the N2 MAC filter (own + broadcast only) drops
#     them (filtered=3) and the ARP-layer drop counter moves (drop=1) —
#     recorded, not a regression.
#   * Honest bound observed: a ping to an OFF-SUBNET address (e.g.
#     8.8.8.8) is refused by the guest itself (`net ping: peer not in
#     ARP table` — no routing rung yet; the NAT router does not
#     proxy-ARP off-subnet addresses). Outbound proof stays at the
#     gateway round trip; external-address runs are optional/manual.
#
# The gate: ONE run on VZ with --net-nat. Script phase 1 sets the
# observed-subnet address, resolves the gateway, and pings it; script
# phase 2 (after the claim-6684 0.5 s settle) re-checks the ARP table
# (the gateway MAC learned) and reads the full `net` report. The
# assertions: the ip-set marker, the ARP request line, the ping-sent
# line, `pong=1` with `seq=1` (the deterministic proof — the NAT
# gateway round trip needs NO internet), the gateway MAC learned, the
# MAC-under-NAT report line, the transport status, and a responsive
# shell.
#
# The FULL 34-gate verify-vz aggregate must stay green (re-run
# separately) — proof the --net-nat mode left the default VM
# byte-identical. Evidence under artifacts/: live-net-nat-*.txt (runner
# output), live-net-nat-*.log (serial copies), and the report.
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-net-nat.sh
#
# Evidence: artifacts/live-net-nat-gate.txt (full output),
# artifacts/live-net-nat-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-net-nat-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-net-nat-report.txt"

echo "=== verify-live-net-nat: claim 4678 — outbound connectivity through VZNATNetworkDeviceAttachment live on VZ (gateway round trip, guest-observed counters) ==="

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

# --- scripted keystrokes ----------------------------------------------------
# The claim-4613 two-phase pattern: --script (phase 1) sets the static
# address on the OBSERVED NAT subnet (192.168.64.0/24, gateway .1),
# resolves the gateway, and pings it; --script2 (forwarded only after
# the phase-1 ready marker, with the claim-6684 0.5 s settle) runs the
# OBSERVATION commands — the ARP-table re-check (the gateway MAC must
# be learned) and the full `net` report. Deterministic, not a sleep
# race: the ARP reply and the echo reply land in the polled RX drain
# during shell idle between the commands, exactly as observed at claim
# time (artifacts/live-net-nat-explore/).
cat > artifacts/live-net-nat-script-1.txt <<'EOF'
net ip 192.168.64.5
net arp 192.168.64.1
net ping 192.168.64.1
echo nat-phase1-ready
EOF
cat > artifacts/live-net-nat-script-2.txt <<'EOF'
net arp 192.168.64.1
net arp
net
echo nat-obs-done
EOF

# --- per-run gate ------------------------------------------------------------
# The ONE run carries every assertion (the card's single-boot gate
# shape). $1 = the runner output file, $2 = the serial log.
run_one() {
    local out="$1" serial="$2"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    # Capture the host's NAT bridge state DURING the run (documentation
    # only — the interface name (bridge0 here) and the router MAC vary
    # per host/boot; the guest-observed learn counters are the gate).
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --net-nat --script artifacts/live-net-nat-script-1.txt \
        --script2 artifacts/live-net-nat-script-2.txt --script2-after "nat-phase1-ready" \
        --script-expect $'nat-obs-done\ndipshit> ' --timeout 40 \
        > "$out" 2>&1 &
    local RUNNER_PID=$!
    sleep 10
    { echo "--- host NAT bridge state during the run ($(date -u '+%Y-%m-%dT%H:%M:%SZ')) ---"
      ifconfig | awk '/^bridge[0-9]+:/{p=1} p{print} /^$/{if(p) exit}' || true
    } > artifacts/live-net-nat-bridge.txt 2>&1 || true
    wait "$RUNNER_PID"
    local RC=$?
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial" || true
    echo "$RC" > /tmp/live-net-nat-rc.txt
}

rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
set +e
run_one "artifacts/live-net-nat-run.txt" "artifacts/live-net-nat-serial.log"
RC="$(cat /tmp/live-net-nat-rc.txt)"
set -e

# --- assertions --------------------------------------------------------------
SERIAL="artifacts/live-net-nat-serial.log"
SERIAL_BYTES=0 IPSET=0 ARPSENT=0 PINGSENT=0 PONG=0 GWLEARNED=0 MACNAT=0 \
ARPLEARN=0 STATUS=0 OBSDONE=0 RUNNERFLAG=0
if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    # The ip-set marker (phase 1).
    grep -a -qF -- "net ip: ip=192.168.64.5" "$SERIAL" && IPSET=1
    # The ARP request went out (42 bytes, the N3 unpadded observation).
    grep -a -qF -- "net arp: request for 192.168.64.1 sent (42 bytes)" "$SERIAL" && ARPSENT=1
    # The ping went out (46 bytes — the peer WAS in the ARP table).
    grep -a -qF -- "net ping: echo request to 192.168.64.1 sent (46 bytes)" "$SERIAL" && PINGSENT=1
    # THE deterministic proof: the NAT gateway answered the echo — pong=1
    # with the echoed sequence seq=1. No internet dependency.
    grep -a -qF -- " icmp=req=1,repl=0,pong=1,drop=0,fail=0,seq=1" "$SERIAL" && PONG=1
    # The gateway MAC was learned (the ARP-table re-check resolves it).
    grep -a -qF -- "net arp: 192.168.64.1 is at " "$SERIAL" && GWLEARNED=1
    # The NAT attachment HONORS the configured locally-administered MAC.
    grep -a -qF -- "net: mac=02:00:00:00:00:01 source=feature" "$SERIAL" && MACNAT=1
    # The report counters: the gateway learned (learn=1), the ARP-layer
    # drop moved once (the router's IPv6-multicast RA — observed stable).
    grep -a -qF -- "net: ip=192.168.64.5 arp=req=1,repl=0,learn=1,drop=1,fail=0" "$SERIAL" && ARPLEARN=1
    # The transport is up (DRIVER_OK through the post-exit re-arm).
    grep -a -qF -- "net: status=0x000000000000000f rearm=1" "$SERIAL" && STATUS=1
    # A responsive shell (the observation echo + the prompt).
    grep -a -qF -- "nat-obs-done" "$SERIAL" && OBSDONE=1
fi
# The runner attached the NAT device (its own report line).
grep -a -qF -- "net-nat: ENABLED (milestone five card N7, claim 4678)" artifacts/live-net-nat-run.txt && RUNNERFLAG=1

{
    echo "nat: rc=$RC serial-bytes=$SERIAL_BYTES ip-set=$IPSET arp-sent=$ARPSENT ping-sent=$PINGSENT pong=$PONG gw-learned=$GWLEARNED mac-nat=$MACNAT arp-learn=$ARPLEARN status=$STATUS obs-done=$OBSDONE runner-flag=$RUNNERFLAG"
} >> "$REPORT"
echo "nat rc=$RC serial-bytes=$SERIAL_BYTES ip-set=$IPSET arp-sent=$ARPSENT ping-sent=$PINGSENT pong=$PONG gw-learned=$GWLEARNED mac-nat=$MACNAT arp-learn=$ARPLEARN status=$STATUS obs-done=$OBSDONE runner-flag=$RUNNERFLAG"

PASS=0
if [ "$RC" = 0 ] && [ "$IPSET" = 1 ] && [ "$ARPSENT" = 1 ] && [ "$PINGSENT" = 1 ] && \
   [ "$PONG" = 1 ] && [ "$GWLEARNED" = 1 ] && [ "$MACNAT" = 1 ] && [ "$ARPLEARN" = 1 ] && \
   [ "$STATUS" = 1 ] && [ "$OBSDONE" = 1 ] && [ "$RUNNERFLAG" = 1 ]; then
    PASS=1
fi

: > "$REPORT"
{
    echo "DIPSHITOS live NAT gate (claim 4678, milestone five card N7) — outbound connectivity through VZNATNetworkDeviceAttachment, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase 1: net ip 192.168.64.5 (the OBSERVED NAT subnet) + net arp 192.168.64.1 + net ping 192.168.64.1"
    echo "phase 2: net arp 192.168.64.1 (gateway MAC learned) + net arp table + the full net report"
    echo "assertions: ip-set, arp-request-sent (42 B), ping-sent (46 B), pong=1 seq=1 (the deterministic gateway round trip — no internet), gateway-MAC learned, MAC-under-NAT 02:00:00:00:00:01 honored, transport status 0x0f, shell responsive, runner attached the NAT device"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-net-nat: PASS — the guest's EXISTING IP stack reached a REAL network through VZNATNetworkDeviceAttachment: the configured locally-administered MAC is honored under NAT (mac=02:00:00:00:00:01 source=feature), the observed subnet/gateway 192.168.64.0/24/.1 was statically addressed (net ip 192.168.64.5), the NAT gateway answered the guest's ARP (the gateway MAC is learned: net arp: 192.168.64.1 is at …, learn=1) and its ICMP echo (pong=1 with seq=1) — the deterministic outbound proof that needs NO internet — and the shell stayed responsive. The evidence shape is guest-observed counters (the capture-file byte-exact pattern does not apply through NAT — the host translates the frames; the card's documented gate-shape change). The default VM is untouched: without --net-nat, config.networkDevices = []."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-net-nat: FAILED — see artifacts/live-net-nat-report.txt, the runner output (live-net-nat-run.txt), the serial log (live-net-nat-serial.log), and the host bridge capture (live-net-nat-bridge.txt)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
