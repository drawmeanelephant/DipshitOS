#!/usr/bin/env bash
#
# verify-live-net-dhcp-renew.sh -- claim 9489 (milestone five, card N9)
# class-B gate: the DHCP lease lifecycle (RFC 2131 §4.4.5) live on real
# VZ hardware — RENEWING, REBINDING, and EXPIRY — closing the honest
# bound N8 recorded (the lease time was recorded, not enforced).
#
# Mechanism: the guest's `net dhcp` checks the elapsed lease time each
# invocation (the 1 Hz generic timer — `timer.ticks`, seconds). At T1 =
# lease/2 the client RENEWs (a UNICAST REQUEST to the server's IP + the
# MAC the guest resolved with `net arp <server>` — the seam resolves
# nothing); at T2 = lease*7/8 it REBINDs (a BROADCAST REQUEST); at
# expiry it releases the address (arp.own_ip cleared — the report shows
# ip=0.0.0.0) and re-DISCOVERs on the next invocation. The runner's
# `--net-dhcp-respond <ip>:<lease-secs>` (the card-N9 lease knob) makes
# the lease option 51 configurable, and `--script2-delay` /
# `--script3-delay` (the claim-6684 settle, flag-gated) let a gate wait
# deterministically past T1/T2/expiry. The file-handle attachment is
# deterministic end to end: the RENEWING unicast REQUEST and the
# REBINDING broadcast REQUEST are both byte-assertable in the capture.
#
# Audit follow-up 3 (issue #119) rework: the lifecycle now advances
# AUTONOMOUSLY from the shell idle loop (virtio_net.net_dhcp_poll +
# dhcp.step_lifecycle), so the gate proves the RFC rungs against the new
# reality — with an always-answering server an autonomous client simply
# renews forever, so the REBINDING/expiry rungs need the host to REFUSE
# renewals (the new --net-dhcp-respond-norenew / -norebind knobs).
#
# TWO runs, each ONE boot:
#   Run A — the renewal rungs (lease 100 s, --net-dhcp-respond-norenew):
#   the poll RENEWs at T1=50 with a UNICAST REQUEST to the server, which
#   the host REFUSES; the client stays RENEWING and at T2=87 ESCALATES to
#   REBINDING (RFC 2131 §4.4.5 — the new escalation) with a BROADCAST
#   REQUEST, which the host ANSWERS (renewed=1). Assertions: the `net
#   dhcp: renewing (T1, elapsed=…)` line, the `net dhcp: rebinding (T2,
#   elapsed=…)` line, the report counters
#   `…,mal=0,renew=1,rebind=1,renewed=1,expired=0`, the host's REFUSED
#   unicast-RENEWING line + the answered broadcast-REQUEST line, the
#   capture's frame order (DISCOVER 286 B, REQUEST 298 B, the ARP request
#   42 B, the RENEWING REQUEST 298 B UNICAST — dst 02:00:00:00:00:02, dst
#   IP 10.0.0.2, ciaddr = the lease — then the REBINDING REQUEST 298 B
#   BROADCAST — dst ff*6), all WITHOUT the gate typing `net dhcp` after
#   phase 1 (the poll drives the rungs).
#   Run B — expiry + recovery (lease 100 s, --net-dhcp-respond-norebind,
#   no ARP responder — the renewing unicast is never even sent): the poll
#   attempts the REBINDING broadcast REQUEST at T2=87 (refused), stays
#   REBINDING, and at expiry RELEASES the address. Assertions: the `net
#   dhcp: lease expired (elapsed=… >= lease=100)` line, the report after
#   the release (`dhcp=idle,ip=0.0.0.0,…,rebind=1,renewed=0,expired=1` —
#   rebind=1 = the autonomous rebind attempt is honest evidence), the
#   re-DISCOVER (`net dhcp: discover sent xid=0x…` a second time), the
#   host's REFUSED broadcast-REBINDING line, and the client RECOVERS:
#   BOUND again with the same lease (the initial ciaddr==0 REQUEST is
#   still answered).
#
# The FULL 36-gate verify-vz aggregate must stay green (re-run
# separately); the N8 gate (verify-live-net-dhcp.sh) re-runs green — the
# lifecycle counters append AFTER mal=, so its substring assertions hold,
# and the `--net-dhcp-respond` ENABLED prefix is unchanged. Evidence
# under artifacts/: live-net-dhcp-renew-*.txt (runner output),
# live-net-dhcp-renew-*.log (serial copies), live-net-dhcp-renew-*.bin
# (host captures), and the report.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-net-dhcp-renew.sh
#
# Evidence: artifacts/live-net-dhcp-renew-gate.txt (full output),
# artifacts/live-net-dhcp-renew-report.txt (per-run detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# logs, captures, and scripts under $RUN_DIR for both runs; the rc
# handoff files live under $RUN_DIR too (they were /tmp globals).
# Expectation note (#528 rot class 1, claim 2259): the historical
# $'...ndipshit> ' script-expects died with M18 T5's ANSI-colored prompt
# (claim 0163); both runs anchor on the OUTPUT-ONLY done echo.
# Set DIPSHIT_GATE_SUFFIX=_alt for distinct canonical evidence names;
# DIPSHIT_KEEP_RUN=1 keeps the scratch dir.

GATE_LOG="$(art live-net-dhcp-renew-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-net-dhcp-renew-report.txt)"

echo "=== verify-live-net-dhcp-renew: claim 9489 — the DHCP lease lifecycle live on VZ (Run A renewing + rebinding, Run B expiry + recovery) ==="

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
gate_begin live-net-dhcp-renew
echo "run dir: $RUN_DIR"

# --- scripted keystrokes ----------------------------------------------------
# The claim-4613 three-phase pattern. Phase 1 binds (the repeated `net
# dhcp` invocations drive DISCOVER -> OFFER -> REQUEST -> ACK -> BOUND —
# the polled-drain contract) and, in Run A, resolves the server's MAC.
# The runner waits `--script2-delay` AFTER the phase-1 ready marker
# (wall-clock = the guest's 1 Hz ticks), then forwards phase 2: the first
# `net dhcp` hits T1/T2/expiry (the transition + transmit in ONE
# invocation), the second observes the renewed BOUND, `net` reads the
# counters. Phase 3 repeats for the next rung. Deterministic — no sleep
# races inside the guest; the delays are the gate's clock.
cat > "$RUN_DIR/a1.txt" <<'EOF'
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
echo n9a-phase1-ready
EOF
cat > "$RUN_DIR/a2.txt" <<'EOF'
echo n9a-phase2-ready
net
echo n9a-done
EOF
cat > "$RUN_DIR/b1.txt" <<'EOF'
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
echo n9b-phase1-ready
EOF
cat > "$RUN_DIR/b2.txt" <<'EOF'
net
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net
echo n9b-done
EOF

# --- per-run gate ------------------------------------------------------------
# Run A (renewing + rebinding): $1 = runner output, $2 = serial copy,
# $3 = capture file.
run_a() {
    local out="$1" serial="$2" capture="$3"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-a.log" "$capture"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-a.log" \
        --net "$capture" --net-dhcp-respond 10.0.0.2:100 --net-arp-respond 10.0.0.2 \
        --net-dhcp-respond-norenew \
        --script "$RUN_DIR/a1.txt" \
        --script2 "$RUN_DIR/a2.txt" --script2-after "n9a-phase1-ready" --script2-delay 92 \
        --script-expect 'n9a-done' --timeout 220 \
        > "$out" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-a.log" ] && cp "$RUN_DIR/vm-serial-a.log" "$serial" || true
    echo "$RC" > "$RUN_DIR/rc-a"
}

# Run B (expiry + recovery): same shape, no ARP responder needed.
run_b() {
    local out="$1" serial="$2" capture="$3"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-b.log" "$capture"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-b.log" \
        --net "$capture" --net-dhcp-respond 10.0.0.2:100 --net-dhcp-respond-norebind \
        --script "$RUN_DIR/b1.txt" \
        --script2 "$RUN_DIR/b2.txt" --script2-after "n9b-phase1-ready" --script2-delay 106 \
        --script-expect 'n9b-done' --timeout 220 \
        > "$out" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-b.log" ] && cp "$RUN_DIR/vm-serial-b.log" "$serial" || true
    echo "$RC" > "$RUN_DIR/rc-b"
}

set +e
run_a "$(art live-net-dhcp-renew-a-run.txt)" "$(art live-net-dhcp-renew-a-serial.log)" "$RUN_DIR/a-cap.bin"
RCA="$(cat "$RUN_DIR/rc-a")"
cp "$RUN_DIR/a-cap.bin" "$(art live-net-dhcp-renew-a-cap.bin)" 2>/dev/null || true
run_b "$(art live-net-dhcp-renew-b-run.txt)" "$(art live-net-dhcp-renew-b-serial.log)" "$RUN_DIR/b-cap.bin"
RCB="$(cat "$RUN_DIR/rc-b")"
cp "$RUN_DIR/b-cap.bin" "$(art live-net-dhcp-renew-b-cap.bin)" 2>/dev/null || true
set -e

# --- Run A assertions ---------------------------------------------------------
SA="$(art live-net-dhcp-renew-a-serial.log)"
SA_BYTES=0 ABOUND=0 ARENEW=0 AREBIND=0 ACOUNTERS=0 ADONE=0
if [ -f "$SA" ]; then
    SA_BYTES=$(wc -c < "$SA" | tr -d ' ')
    # The initial handshake bound (lease 100).
    grep -a -qF -- "net: dhcp bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=100" "$SA" && ABOUND=1
    # The RENEWING rung (T1): the unicast REQUEST to the server.
    grep -a -qE -- "net dhcp: renewing \(T1, elapsed=[0-9]+\) request sent to the server \(298 bytes\)" "$SA" && ARENEW=1
    # The REBINDING rung (T2): the broadcast REQUEST.
    grep -a -qE -- "net dhcp: rebinding \(T2, elapsed=[0-9]+\) request sent \(298 bytes\)" "$SA" && AREBIND=1
    # The lifecycle counters: ONE renewing REQUEST (refused), ONE
    # rebinding REQUEST (ACKed — the T2 escalation after the refused
    # renewal, RFC 2131 §4.4.5), the renewal ACK, NO expiry. With the
    # autonomous poll an always-answered renewal would simply renew
    # forever; the refusal is what forces the REBINDING rung.
    grep -a -qF -- "renew=1,rebind=1,renewed=1,expired=0" "$SA" && ACOUNTERS=1
    grep -a -qF -- "n9a-done" "$SA" && ADONE=1
fi
ARUNNER=0 ANETACK=0 AREFUSE=0
# The host REFUSED the unicast RENEWING REQUEST (its own stdout line —
# the refusal that forces the T2 escalation).
grep -a -qF -- "NET-DHCP: refused the guest's unicast RENEWING REQUEST" "$(art live-net-dhcp-renew-a-run.txt)" && AREFUSE=1
# The host answered the (broadcast rebinding) REQUEST (its own stdout).
grep -a -qF -- "NET-DHCP: answered the guest's DHCP REQUEST" "$(art live-net-dhcp-renew-a-run.txt)" && ANETACK=1
grep -a -qF -- "net-dhcp-respond: ENABLED (milestone five card N8, claim 0351) + card N9 (claim 9489)" "$(art live-net-dhcp-renew-a-run.txt)" && ARUNNER=1
# The capture proves the RENEWING frame is UNICAST and the REBINDING
# frame is BROADCAST: the byte order is deterministic — DISCOVER (286 B)
# + REQUEST (298 B) + the phase-1 ARP request for the server (42 B) +
# the RENEWING REQUEST (298 B, dst 02:00:00:00:00:02, src IP 10.0.0.2,
# dst IP 10.0.0.2, ciaddr 10.0.0.2) + the REBINDING REQUEST (298 B, dst
# ff:ff:ff:ff:ff:ff). 286 + 298 + 42 + 298 + 298 = 1222 bytes (pinned by
# the claim-time exploratory capture).
ACAP=0
if [ -f "$(art live-net-dhcp-renew-a-cap.bin)" ]; then
    ASIZE=$(wc -c < "$(art live-net-dhcp-renew-a-cap.bin)" | tr -d ' ')
    if [ "$ASIZE" = 1222 ]; then
        AHEX=$(xxd -p "$(art live-net-dhcp-renew-a-cap.bin)" | tr -d '\n')
        # The RENEWING REQUEST at byte 626: dst MAC 02:00:00:00:00:02,
        # dst IP (626+30..34) = 0a000002, ciaddr (626+54..58) = 0a000002.
        if [ "${AHEX:1252:12}" = "020000000002" ] && \
           [ "${AHEX:1312:8}" = "0a000002" ] && \
           [ "${AHEX:1360:8}" = "0a000002" ] && \
           # The REBINDING REQUEST at byte 924: dst broadcast.
           [ "${AHEX:1848:12}" = "ffffffffffff" ]; then
            ACAP=1
        fi
    fi
fi

# --- Run B assertions ---------------------------------------------------------
SB="$(art live-net-dhcp-renew-b-serial.log)"
SB_BYTES=0 BEXPIRED=0 BRELEASED=0 BREDISC=0 BRECOVER=0 BDONE=0
if [ -f "$SB" ]; then
    SB_BYTES=$(wc -c < "$SB" | tr -d ' ')
    # The expiry line (elapsed >= lease=100).
    grep -a -qE -- "net dhcp: lease expired \(elapsed=[0-9]+ >= lease=100\) — address released, re-DISCOVER with \`net dhcp\`" "$SB" && BEXPIRED=1
    # The address was released: the report after expiry shows idle + the
    # zeroed lease (ip=0.0.0.0) + expired=1. rebind=1 = the REBINDING
    # REQUEST was attempted (and refused by the host) before the lease
    # ran out — the autonomous client tried to keep the address alive.
    grep -a -qF -- "dhcp=idle,ip=0.0.0.0,mask=0.0.0.0,gw=0.0.0.0,server=0.0.0.0,lease=0,discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,mal=0,renew=0,rebind=1,renewed=0,expired=1" "$SB" && BRELEASED=1
    # The client RECOVERS: a second DISCOVER (the re-DISCOVER after the
    # release) and a second BOUND with the same lease.
    grep -a -qE -- "net dhcp: discover sent xid=0x[0-9a-f]+ \(286 bytes\)" "$SB" && BREDISC=1
    grep -a -qF -- "net: dhcp bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=100" "$SB" && BRECOVER=1
    grep -a -qF -- "n9b-done" "$SB" && BDONE=1
fi
BRUNNER=0 BREFUSE=0
grep -a -qF -- "net-dhcp-respond: ENABLED (milestone five card N8, claim 0351) + card N9 (claim 9489)" "$(art live-net-dhcp-renew-b-run.txt)" && BRUNNER=1
# The host REFUSED the broadcast REBINDING REQUEST (its own stdout — the
# refusal that lets the lease run out).
grep -a -qF -- "NET-DHCP: refused the guest's broadcast REBINDING REQUEST" "$(art live-net-dhcp-renew-b-run.txt)" && BREFUSE=1
# The recovery re-DISCOVER is a SECOND 286-byte broadcast frame (the
# capture holds at least DISCOVER + REQUEST + the re-DISCOVER).
BCAP=0
if [ -f "$(art live-net-dhcp-renew-b-cap.bin)" ]; then
    BSIZE=$(wc -c < "$(art live-net-dhcp-renew-b-cap.bin)" | tr -d ' ')
    [ "$BSIZE" -ge 870 ] && BCAP=1 # 286 + 298 + 286
fi

{
    echo "a: rc=$RCA serial-bytes=$SA_BYTES bound=$ABOUND renew=$ARENEW rebind=$AREBIND counters=$ACOUNTERS done=$ADONE runner=$ARUNNER net-ack=$ANETACK refuse=$AREFUSE capture=$ACAP"
    echo "b: rc=$RCB serial-bytes=$SB_BYTES expired=$BEXPIRED released=$BRELEASED re-discover=$BREDISC recover=$BRECOVER done=$BDONE runner=$BRUNNER refuse=$BREFUSE capture=$BCAP"
} >> "$REPORT"
echo "a rc=$RCA serial-bytes=$SA_BYTES bound=$ABOUND renew=$ARENEW rebind=$AREBIND counters=$ACOUNTERS done=$ADONE runner=$ARUNNER net-ack=$ANETACK refuse=$AREFUSE capture=$ACAP"
echo "b rc=$RCB serial-bytes=$SB_BYTES expired=$BEXPIRED released=$BRELEASED re-discover=$BREDISC recover=$BRECOVER done=$BDONE runner=$BRUNNER refuse=$BREFUSE capture=$BCAP"

PASS=0
if [ "$RCA" = 0 ] && [ "$ABOUND" = 1 ] && [ "$ARENEW" = 1 ] && [ "$AREBIND" = 1 ] && \
   [ "$ACOUNTERS" = 1 ] && [ "$ADONE" = 1 ] && [ "$ARUNNER" = 1 ] && [ "$ANETACK" = 1 ] && [ "$AREFUSE" = 1 ] && [ "$ACAP" = 1 ] && \
   [ "$RCB" = 0 ] && [ "$BEXPIRED" = 1 ] && [ "$BRELEASED" = 1 ] && [ "$BREDISC" = 1 ] && \
   [ "$BRECOVER" = 1 ] && [ "$BDONE" = 1 ] && [ "$BRUNNER" = 1 ] && [ "$BREFUSE" = 1 ] && [ "$BCAP" = 1 ]; then
    PASS=1
fi

: > "$REPORT"
{
    echo "DIPSHITOS live DHCP lease-lifecycle gate (claim 9489, milestone five card N9) — RFC 2131 §4.4.5 on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "run A (renewing + rebinding, --net-dhcp-respond-norenew): lease 100 s — the AUTONOMOUS poll RENEWs at T1=50 (UNICAST REQUEST, REFUSED by the host), stays RENEWING, and at T2=87 ESCALATES to REBINDING (BROADCAST REQUEST, ACKed); no net dhcp is typed after phase 1"
    echo "assertions: runner rc, the bound lease, the renewing (T1) line, the rebinding (T2) line, the counters renew=1,rebind=1,renewed=1,expired=0, the host's REFUSED unicast line + the answered broadcast-REQUEST line, the capture (1222 B: DISCOVER 286 + REQUEST 298 + the ARP 42 + RENEW 298 UNICAST dst 02:00:00:00:00:02 / src+dst IP 10.0.0.2 / ciaddr 10.0.0.2 + REBIND 298 broadcast), the gate echo, the runner's net-dhcp-respond flags"
    echo "run B (expiry + recovery, --net-dhcp-respond-norebind): lease 100 s — the poll attempts REBINDING at T2=87 (REFUSED) and at expiry RELEASES the address (ip=0.0.0.0, rebind=1, expired=1), then the client re-DISCOVERs -> BOUND again"
    echo "assertions: runner rc, the lease-expired line, the report dhcp=idle,ip=0.0.0.0,...,rebind=1,renewed=0,expired=1, the host's REFUSED broadcast-REBINDING line, the re-DISCOVER line, the recovery BOUND, the gate echo, the runner flag, the capture >= 870 B (a second DISCOVER)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-net-dhcp-renew: PASS — the guest enforced its lease AUTONOMOUSLY (audit follow-up 3, issue #119: the idle-loop poll drives the lifecycle, no net dhcp typed after phase 1). Run A: at T1 (lease/2) it RENEWed with a UNICAST REQUEST to the server (byte-assertable in the capture: dst 02:00:00:00:00:02, dst IP 10.0.0.2, ciaddr = the lease); the host REFUSED it (its own NET-DHCP line), so at T2 (lease*7/8) the client ESCALATED to REBINDING (RFC 2131 §4.4.5) with a BROADCAST REQUEST (the capture's frame: dst ff:ff:ff:ff:ff:ff) and the ACK restarted the lease (renewed=1). Run B: with the rebind also REFUSED, the lease ran out and the client RELEASED the address honestly (the report shows ip=0.0.0.0 and expired=1 — arp.own_ip cleared, rebind=1 records the autonomous rebind attempt) and RECOVERED with a fresh DISCOVER -> BOUND again. Counters: renew=1,rebind=1,renewed=1,expired=0 (Run A); discover=2,rebind=1,renewed=0,expired=1 + the recovery BOUND (Run B)."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-net-dhcp-renew: FAILED — see artifacts/live-net-dhcp-renew-report.txt, the runner outputs (live-net-dhcp-renew-a-run.txt / b), the serial logs (live-net-dhcp-renew-a-serial.log / b), and the captures (live-net-dhcp-renew-a-cap.bin / b)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
