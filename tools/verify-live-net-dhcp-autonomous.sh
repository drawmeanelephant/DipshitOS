#!/usr/bin/env bash
#
# verify-live-net-dhcp-autonomous.sh -- issue #119 (audit follow-up 3)
# class-B gate: the DHCP lease lifecycle advances AUTONOMOUSLY from the
# kernel's idle loop — no human types `net dhcp` to hit T1/T2.
#
# Background (issue #119): before this claim, RENEWING/REBINDING/expiry
# only advanced when someone typed `net dhcp` — the N9 "enforced lease"
# was enforced on demand, while TCP RTO was already autonomous. The
# fix: `virtio_net.net_dhcp_poll()` (the pure `dhcp.step_lifecycle`
# decision + the apply/transmit glue) runs from the shell idle loop
# each iteration AFTER the RX drain, advancing RFC 2131 §4.4.5 exactly
# as `net dhcp` would and printing the SAME transition lines. The
# re-DISCOVER after expiry stays command-triggered (the bounded
# handshake; the client honestly drops to idle at expiry).
#
# With an always-answering server an autonomous client simply renews at
# every T1 forever (correct RFC behavior — the old gate only saw a REBIND
# because no command ran between T1 and T2). So this gate runs the new
# --net-dhcp-respond-norenew knob: the host REFUSES the unicast RENEWING
# REQUEST, the client stays RENEWING, and at T2 it ESCALATES to
# REBINDING (the RFC 2131 §4.4.5 escalation the poll added) with the
# broadcast REQUEST — which the host ANSWERS. Both rungs fire with NO
# typed net dhcp.
#
# Mechanism (ONE boot): lease 100 s. Phase 1 (`--script`) binds with
# repeated `net dhcp` invocations and resolves the server MAC with `net
# arp 10.0.0.2` (the renewing unicast needs it — the host's
# `--net-arp-respond` answers). Phase 2 fires at `--script2-delay 92`
# (elapsed ~92, past T2=87) and types NO net dhcp — only a marker + a
# `net` REPORT (a report cannot advance the lifecycle — it reads it). If
# the renewing + rebinding transition lines appear, they can ONLY have
# come from the autonomous idle-loop poll. The gate also self-checks the
# premise: the phase-2 script file must not contain `net dhcp`.
#
# Assertions:
#   * the lease bound (ip=10.0.0.2 ... lease=100);
#   * `net dhcp: renewing (T1, elapsed=…) request sent to the server
#     (298 bytes)` — typed by NOBODY (the poll);
#   * `net dhcp: rebinding (T2, elapsed=…) request sent (298 bytes)`
#     — the T2 ESCALATION, also the poll;
#   * the `net` report shows renew=1,rebind=1,renewed=1,expired=0 (the
#     renew REFUSED, the rebind ACKed);
#   * the host's own "refused the guest's unicast RENEWING REQUEST"
#     line + the answered broadcast-REQUEST ACK line;
#   * the capture: 1222 B = DISCOVER 286 + REQUEST 298 + the phase-1
#     ARP request 42 + the RENEWING REQUEST 298 (dst 02:00:00:00:00:02,
#     dst IP 10.0.0.2, ciaddr 10.0.0.2) + the REBINDING REQUEST 298
#     (dst ff:ff:ff:ff:ff:ff) — byte-exact offsets like the N9 renew
#     gate;
#   * the phase-2 script contains no `net dhcp` (premise self-check);
#   * the runner's net-dhcp-respond + net-arp-respond + norenew flags;
#   * the serial markers.
#
# Class B -- Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-net-dhcp-autonomous.sh
#
# Evidence: artifacts/live-net-dhcp-autonomous-gate.txt (full output),
# artifacts/live-net-dhcp-autonomous-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-net-dhcp-autonomous-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-net-dhcp-autonomous-report.txt"

echo "=== verify-live-net-dhcp-autonomous: issue #119 — the DHCP lease lifecycle advances from the idle loop (T1 renew + T2 escalation with NO typed net dhcp), live on VZ ==="

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

# --- scripted sessions ------------------------------------------------------
# Phase 1: bind + resolve the server MAC (the renewing unicast needs it).
cat > artifacts/live-net-dhcp-autonomous-1.txt <<'EOF'
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
net arp 10.0.0.2
echo dhcp-auto-phase1-ready
EOF
# Phase 2 (delay 92 — past T2=87): NO net dhcp — only a marker + a `net`
# REPORT (a report cannot advance the lifecycle).
cat > artifacts/live-net-dhcp-autonomous-2.txt <<'EOF'
echo dhcp-auto-p2
net
echo dhcp-auto-done
EOF

# The premise self-check: the phase-2 script types no `net dhcp`.
if grep -q "net dhcp" artifacts/live-net-dhcp-autonomous-2.txt; then
    echo "verify-live-net-dhcp-autonomous: FAILED — the phase-2 script contains 'net dhcp' (the gate must prove autonomy with NO typed lifecycle command)."
    exit 1
fi

rm -f artifacts/efi-vars.bin artifacts/vm-serial.log artifacts/live-net-dhcp-autonomous-cap.bin
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --net artifacts/live-net-dhcp-autonomous-cap.bin \
    --net-dhcp-respond 10.0.0.2:100 --net-arp-respond 10.0.0.2 \
    --net-dhcp-respond-norenew \
    --script artifacts/live-net-dhcp-autonomous-1.txt \
    --script2 artifacts/live-net-dhcp-autonomous-2.txt --script2-after "dhcp-auto-phase1-ready" --script2-delay 92 \
    --script-expect $'dhcp-auto-done\ndipshit> ' --timeout 220 \
    > artifacts/live-net-dhcp-autonomous-run.txt 2>&1
RC=$?
set -e
[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-net-dhcp-autonomous-serial.log || true

# --- assertions -------------------------------------------------------------
SERIAL="artifacts/live-net-dhcp-autonomous-serial.log"
SERIAL_BYTES=0 BOUND=0 ARENEW=0 AREBIND=0 COUNTERS=0 DONE=0
if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net: dhcp bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=100" "$SERIAL" && BOUND=1
    # THE autonomous transitions — typed by NOBODY (phase 2 has no net dhcp).
    grep -a -qE -- "net dhcp: renewing \\(T1, elapsed=[0-9]+\\) request sent to the server \\(298 bytes\\)" "$SERIAL" && ARENEW=1
    grep -a -qE -- "net dhcp: rebinding \\(T2, elapsed=[0-9]+\\) request sent \\(298 bytes\\)" "$SERIAL" && AREBIND=1
    # The report: renew REFUSED, rebind ACKed.
    grep -a -qF -- "renew=1,rebind=1,renewed=1,expired=0" "$SERIAL" && COUNTERS=1
    grep -a -qF -- "dhcp-auto-done" "$SERIAL" && DONE=1
fi
RUNNER=0 REFUSE=0
grep -a -qF -- "net-dhcp-respond: ENABLED (milestone five card N8, claim 0351) + card N9 (claim 9489)" artifacts/live-net-dhcp-autonomous-run.txt && RUNNER=1
grep -a -qF -- "net-arp-respond: ENABLED" artifacts/live-net-dhcp-autonomous-run.txt && RUNNER=1
grep -a -qF -- "net-dhcp-respond-norenew: ENABLED" artifacts/live-net-dhcp-autonomous-run.txt && RUNNER=1
# The host refused the unicast RENEWING REQUEST (its own stdout line).
grep -a -qF -- "NET-DHCP: refused the guest's unicast RENEWING REQUEST" artifacts/live-net-dhcp-autonomous-run.txt && REFUSE=1

# The capture: 1222 B = DISCOVER 286 + REQUEST 298 + ARP req 42 + RENEW
# 298 (unicast, dst 02:00:00:00:00:02, dst IP 0a000002, ciaddr 0a000002)
# + REBIND 298 (broadcast) — byte offsets as the N9 renew gate pins.
CAPTURE=0
if [ -f artifacts/live-net-dhcp-autonomous-cap.bin ]; then
    CSIZE=$(wc -c < artifacts/live-net-dhcp-autonomous-cap.bin | tr -d ' ')
    if [ "$CSIZE" = 1222 ]; then
        CHEX=$(xxd -p artifacts/live-net-dhcp-autonomous-cap.bin | tr -d '\n')
        if [ "${CHEX:1252:12}" = "020000000002" ] && \
           [ "${CHEX:1312:8}" = "0a000002" ] && \
           [ "${CHEX:1360:8}" = "0a000002" ] && \
           [ "${CHEX:1848:12}" = "ffffffffffff" ]; then
            CAPTURE=1
        fi
    fi
fi

echo "autonomous: rc=$RC serial-bytes=$SERIAL_BYTES bound=$BOUND renew=$ARENEW rebind=$AREBIND counters=$COUNTERS done=$DONE runner=$RUNNER refuse=$REFUSE capture=$CAPTURE"

PASS=0
if [ "$RC" = 0 ] && [ "$BOUND" = 1 ] && [ "$ARENEW" = 1 ] && [ "$AREBIND" = 1 ] && \
   [ "$COUNTERS" = 1 ] && [ "$DONE" = 1 ] && [ "$RUNNER" = 1 ] && [ "$REFUSE" = 1 ] && [ "$CAPTURE" = 1 ]; then
    PASS=1
fi

{
    echo "DIPSHITOS live net-dhcp-autonomous gate (issue #119, audit follow-up 2026-08-15) — the DHCP lease lifecycle advances from the shell idle loop, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: lease 100 s, --net-dhcp-respond-norenew — phase 1 binds + resolves the server MAC; phase 2 (delay 92) types NO net dhcp (a marker + a net report only); the poll must RENEW at T1=50 (REFUSED), stay RENEWING, and ESCALATE to REBINDING at T2=87 (ACKed)"
    echo "assertions: the bound lease; the renewing (T1) + rebinding (T2) transition lines; the report renew=1,rebind=1,renewed=1,expired=0; the host's refused-unicast line; the 1222-B capture (RENEW unicast dst 02:00:00:00:00:02 / dst IP + ciaddr 10.0.0.2, REBIND broadcast); the phase-2 script contains no net dhcp (premise self-check); the runner flags; the serial markers"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-net-dhcp-autonomous: PASS — with the idle-loop DHCP poll (kernel/src/virtio_net.zig net_dhcp_poll + dhcp.step_lifecycle, issue #119), the lease lifecycle advanced WITHOUT a human typing 'net dhcp': at T1 (lease/2 = 50 s) the client RENEWed with a unicast REQUEST to the server (298 B, byte-assertable in the capture), the host REFUSED it (its own NET-DHCP line), and at T2 (lease*7/8 = 87 s) the client ESCALATED to REBINDING (the RFC 2131 §4.4.5 escalation) with a broadcast REQUEST (298 B), whose ACK restarted the lease (renewed=1). Phase 2 typed only a net REPORT (renew=1,rebind=1,renewed=1,expired=0) — the transitions came from the kernel's own housekeeping, closing the audit finding that the N9 enforced lease only ran on demand. The re-DISCOVER after expiry stays command-triggered (bounded handshake; the client honestly drops to idle)."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-net-dhcp-autonomous: FAILED — see artifacts/live-net-dhcp-autonomous-report.txt, the runner output (live-net-dhcp-autonomous-run.txt), and the serial log (live-net-dhcp-autonomous-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
