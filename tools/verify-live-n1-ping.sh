#!/usr/bin/env bash
#
# verify-live-n1-ping.sh -- M26 N1 (issue #399, claim 0640) class-B gate:
# PING.BIN running at EL0 on real VZ hardware, sending ICMP echo requests
# through the sys_ping_send/poll syscalls (slots 59/60), receiving echo replies
# from the host runner (--net-icmp-respond 10.0.0.2), printing live RTT stats,
# computing packet loss, and cleanly exiting status 0.
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-n1-ping-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-n1-ping-report.txt)"

echo "=== verify-live-n1-ping: M26 N1 — ICMP ping PING.BIN live on VZ (EL0 ICMP echo, host responder, RTT statistics) ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
PATH=/opt/homebrew/bin:/bin:/usr/bin zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
PATH=/opt/homebrew/bin:/bin:/usr/bin zig build
PATH=/opt/homebrew/bin:/bin:/usr/bin zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-n1-ping
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec PING.BIN -c 3 10.0.0.2
echo ping-launched
EOF
cat > "$RUN_DIR/script-2.txt" <<'EOF'
procs
echo ping-ok
EOF

# --- the run ----------------------------------------------------------------
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --net "$RUN_DIR/cap.bin" \
    --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 \
    --script "$RUN_DIR/script-1.txt" \
    --script2 "$RUN_DIR/script-2.txt" --script2-after 'ping statistics' \
    --script-expect $'tasks user-exec reaped' --timeout 60 \
    > "$(art live-n1-ping-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-n1-ping-serial.log)" || true

# --- assertions -------------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
SERIAL_BYTES=0; IPSET=0; ARPSET=0
P_HDR=0; P_SEQ1=0; P_SEQ2=0; P_SEQ3=0; P_STAT=0; P_LOSS=0; P_RTT=0; P_REAPED=0; OK=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IPSET=1
    grep -a -E -- "net arp: (request for|resolved)" "$SERIAL" && ARPSET=1
    grep -a -qF -- "PING 10.0.0.2 (10.0.0.2): 56 data bytes" "$SERIAL" && P_HDR=1
    grep -a -qF -- "64 bytes from 10.0.0.2: icmp_seq=1" "$SERIAL" && P_SEQ1=1
    grep -a -qF -- "64 bytes from 10.0.0.2: icmp_seq=2" "$SERIAL" && P_SEQ2=1
    grep -a -qF -- "64 bytes from 10.0.0.2: icmp_seq=3" "$SERIAL" && P_SEQ3=1
    grep -a -qF -- "--- 10.0.0.2 ping statistics ---" "$SERIAL" && P_STAT=1
    grep -a -qF -- "3 packets transmitted, 3 packets received, 0% packet loss" "$SERIAL" && P_LOSS=1
    grep -a -qF -- "round-trip min/avg/max =" "$SERIAL" && P_RTT=1
    grep -a -E -- "PING.BIN.*state=exited.*0|PING.BIN[[:space:]]+exit=0x0000000000000000" "$SERIAL" && P_REAPED=1
    grep -a -qF -- "echo ping-ok" "$SERIAL" && OK=1
fi

echo "--- serial log excerpt ---"
[ -f "$SERIAL" ] && head -n 40 "$SERIAL" || echo "(no serial log)"

echo "--- assertions summary ---"
echo "  ipset: $IPSET"
echo "  arpset: $ARPSET"
echo "  p_hdr: $P_HDR"
echo "  p_seq1: $P_SEQ1"
echo "  p_seq2: $P_SEQ2"
echo "  p_seq3: $P_SEQ3"
echo "  p_stat: $P_STAT"
echo "  p_loss: $P_LOSS"
echo "  p_rtt: $P_RTT"
echo "  p_reaped: $P_REAPED"
echo "  ok: $OK"
echo "  runner exit code: $RC"

cat > "$REPORT" <<EOF
verify-live-n1-ping report
==========================
revision: $REVISION
branch: $BRANCH
serial_bytes: $SERIAL_BYTES
ipset: $IPSET
arpset: $ARPSET
p_hdr: $P_HDR
p_seq1: $P_SEQ1
p_seq2: $P_SEQ2
p_seq3: $P_SEQ3
p_stat: $P_STAT
p_loss: $P_LOSS
p_rtt: $P_RTT
p_reaped: $P_REAPED
ok: $OK
rc: $RC
EOF

if [ "$IPSET" -eq 1 ] && [ "$ARPSET" -eq 1 ] && [ "$P_HDR" -eq 1 ] && \
   [ "$P_SEQ1" -eq 1 ] && [ "$P_SEQ2" -eq 1 ] && [ "$P_SEQ3" -eq 1 ] && \
   [ "$P_STAT" -eq 1 ] && [ "$P_LOSS" -eq 1 ] && [ "$P_RTT" -eq 1 ] && \
   [ "$P_REAPED" -eq 1 ] && [ "$OK" -eq 1 ] && [ "$RC" -eq 0 ]; then
    echo "verify-live-n1-ping: PASS"
    exit 0
else
    echo "verify-live-n1-ping: FAIL"
    exit 1
fi
