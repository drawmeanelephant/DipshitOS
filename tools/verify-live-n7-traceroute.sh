#!/usr/bin/env bash
#
# verify-live-n7-traceroute.sh -- M26 N7 (issue #434, claim 7635) class-B gate:
# TRACEROUTE.BIN / TRACEROU.BIN running at EL0 on real VZ hardware,
# sending ICMP route probes to host runner (--net-icmp-respond 10.0.0.2),
# measuring hop RTT, reporting path hops, and cleanly exiting status 0.
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-n7-traceroute-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-n7-traceroute-report.txt)"

echo "=== verify-live-n7-traceroute: M26 N7 — ICMP traceroute TRACEROUTE.BIN live on VZ (EL0 path diagnostics, hop RTT, clean exit) ==="

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
gate_begin live-n7-traceroute
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec TRACEROU.BIN
echo trace-launched
EOF
cat > "$RUN_DIR/script-2.txt" <<'EOF'
procs
echo trace-ok
EOF

# --- the run ----------------------------------------------------------------
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --net "$RUN_DIR/cap.bin" \
    --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 \
    --script "$RUN_DIR/script-1.txt" \
    --script2 "$RUN_DIR/script-2.txt" --script2-after 'traceroute: complete' \
    --script-expect $'tasks user-exec reaped' --timeout 60 \
    > "$(art live-n7-traceroute-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-n7-traceroute-serial.log)" || true

# --- assertions -------------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
SERIAL_BYTES=0; IPSET=0; ARPSET=0
T_START=0; T_HDR=0; T_HOP=0; T_SUM=0; T_DONE=0; T_REAPED=0; OK=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IPSET=1
    grep -a -E -- "net arp: (request for|resolved)" "$SERIAL" && ARPSET=1
    grep -a -qF -- "traceroute: starting" "$SERIAL" && T_START=1
    grep -a -qF -- "traceroute to 10.0.0.2" "$SERIAL" && T_HDR=1
    grep -a -E -- "1[[:space:]]+10\.0\.0\.2" "$SERIAL" && T_HOP=1
    grep -a -qF -- "traceroute: reached 10.0.0.2 in 1 hop(s)" "$SERIAL" && T_SUM=1
    grep -a -qF -- "traceroute: complete" "$SERIAL" && T_DONE=1
    grep -a -E -- "TRACEROU.*state=exited.*0|TRACEROU[[:space:]]+exit=0x0000000000000000" "$SERIAL" && T_REAPED=1
    grep -a -qF -- "echo trace-ok" "$SERIAL" && OK=1
fi

echo "--- serial log excerpt ---"
[ -f "$SERIAL" ] && head -n 40 "$SERIAL" || echo "(no serial log)"

echo "--- assertions summary ---"
echo "  ipset: $IPSET"
echo "  arpset: $ARPSET"
echo "  t_start: $T_START"
echo "  t_hdr: $T_HDR"
echo "  t_hop: $T_HOP"
echo "  t_sum: $T_SUM"
echo "  t_done: $T_DONE"
echo "  t_reaped: $T_REAPED"
echo "  ok: $OK"

TOTAL=$((IPSET + ARPSET + T_START + T_HDR + T_HOP + T_SUM + T_DONE + T_REAPED + OK))

cat > "$REPORT" <<EOF
test: verify-live-n7-traceroute (M26 N7 — TRACEROUTE.BIN live on VZ)
revision: $REVISION
branch: $BRANCH
dirty_files: $DIRTY
runner_exit_code: $RC
serial_log_bytes: $SERIAL_BYTES
assertions_passed: $TOTAL/9
  ipset: $IPSET
  arpset: $ARPSET
  t_start: $T_START
  t_hdr: $T_HDR
  t_hop: $T_HOP
  t_sum: $T_SUM
  t_done: $T_DONE
  t_reaped: $T_REAPED
  ok: $OK
status: $([ "$TOTAL" -eq 9 ] && echo PASS || echo FAIL)
EOF

if [ "$TOTAL" -ne 9 ]; then
    echo "=== verify-live-n7-traceroute: FAIL ($TOTAL/9 assertions passed) ==="
    exit 1
fi

echo "=== verify-live-n7-traceroute: PASS ==="
exit 0
