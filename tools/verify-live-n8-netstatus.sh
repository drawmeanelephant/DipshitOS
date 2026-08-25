#!/usr/bin/env bash
#
# verify-live-n8-netstatus.sh -- M26 N8 / N15 / N16 (issues #435, #442, #443) class-B gate:
# Verifies the net status summary command (N8), net route inspection command (N16),
# and net log event viewer (N15) running in the monitor on real VZ hardware.
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-n8-netstatus-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-n8-netstatus-report.txt)"

echo "=== verify-live-n8-netstatus: M26 N8/N15/N16 — net status, route, log live on VZ ==="

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
gate_begin live-n8-netstatus
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net status
net ip 10.0.0.1
net status
net route
net arp 10.0.0.2
net log
echo netstatus-ok
EOF

# --- the run ----------------------------------------------------------------
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --net "$RUN_DIR/cap.bin" \
    --net-arp-respond 10.0.0.2 \
    --script "$RUN_DIR/script-1.txt" \
    --script-expect $'echo netstatus-ok' --timeout 30 \
    > "$(art live-n8-netstatus-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-n8-netstatus-serial.log)" || true

# --- assertions -------------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
SERIAL_BYTES=0; S_INIT=0; IP_SET=0; S_BOUND=0; R_TABLE=0; R_ENTRY=0; L_HDR=0; L_IP=0; L_ARP=0; OK=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net status: IP: 0.0.0.0" "$SERIAL" && S_INIT=1
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IP_SET=1
    grep -a -qF -- "net status: IP: 10.0.0.1 Gateway: 10.0.0.2 DNS: 10.0.0.2" "$SERIAL" && S_BOUND=1
    grep -a -qF -- "net route: table" "$SERIAL" && R_TABLE=1
    grep -a -qF -- "0.0.0.0/0" "$SERIAL" && R_ENTRY=1
    grep -a -qF -- "net log: entries=" "$SERIAL" && L_HDR=1
    grep -a -qF -- "IP: assigned 10.0.0.1" "$SERIAL" && L_IP=1
    grep -a -qF -- "ARP: request 10.0.0.2" "$SERIAL" && L_ARP=1
    grep -a -qF -- "echo netstatus-ok" "$SERIAL" && OK=1
fi

echo "--- serial log excerpt ---"
[ -f "$SERIAL" ] && head -n 50 "$SERIAL" || echo "(no serial log)"

echo "--- assertions summary ---"
echo "  s_init: $S_INIT"
echo "  ip_set: $IP_SET"
echo "  s_bound: $S_BOUND"
echo "  r_table: $R_TABLE"
echo "  r_entry: $R_ENTRY"
echo "  l_hdr: $L_HDR"
echo "  l_ip: $L_IP"
echo "  l_arp: $L_ARP"
echo "  ok: $OK"

PASS=1
[ "$S_INIT" -eq 1 ] || PASS=0
[ "$IP_SET" -eq 1 ] || PASS=0
[ "$S_BOUND" -eq 1 ] || PASS=0
[ "$R_TABLE" -eq 1 ] || PASS=0
[ "$R_ENTRY" -eq 1 ] || PASS=0
[ "$L_HDR" -eq 1 ] || PASS=0
[ "$L_IP" -eq 1 ] || PASS=0
[ "$L_ARP" -eq 1 ] || PASS=0
[ "$OK" -eq 1 ] || PASS=0

cat > "$REPORT" <<EOF
verify-live-n8-netstatus: exit=$RC pass=$PASS
revision=$REVISION branch=$BRANCH dirty=$DIRTY
bytes=$SERIAL_BYTES
s_init=$S_INIT ip_set=$IP_SET s_bound=$S_BOUND r_table=$R_TABLE r_entry=$R_ENTRY l_hdr=$L_HDR ok=$OK
EOF

if [ "$PASS" -eq 1 ]; then
    echo "=== verify-live-n8-netstatus: PASS ==="
    exit 0
else
    echo "=== verify-live-n8-netstatus: FAIL ==="
    exit 1
fi
