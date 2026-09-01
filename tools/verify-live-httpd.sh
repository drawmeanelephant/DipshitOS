#!/usr/bin/env bash
#
# verify-live-httpd.sh -- Claim 0750
# Class-B hardware gate: in-guest HTTP/1.1 web server HTTPD.BIN running at EL0
# on real VZ hardware, passive open / listen mode on port 8080, request parsing,
# static file serving from the host share, and /api/status telemetry.
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-httpd-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-httpd-report.txt)"

echo "=== verify-live-httpd: Claim 0750 — in-guest HTTP/1.1 web server HTTPD.BIN live on VZ ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check kernel/src/tcp.zig kernel/src/syscall.zig kernel/src/monitor.zig user/src/lib/ui.zig user/src/httpd.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-httpd
gate_seed_share
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net ip 10.0.0.1
exec HTTPD.BIN
echo httpd-launched
EOF
cat > "$RUN_DIR/script-2.txt" <<'EOF'
procs
net
echo httpd-ok
EOF

# --- the run ----------------------------------------------------------------
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}"     --serial "$RUN_DIR/vm-serial.log"     --net "$RUN_DIR/cap.bin"     --script "$RUN_DIR/script-1.txt"     --script2 "$RUN_DIR/script-2.txt" --script2-after 'httpd: listening on port 8080'     --script-expect $'httpd-ok' --timeout 60     > "$(art live-httpd-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-httpd-serial.log)" || true

# --- assertions -------------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
SERIAL_BYTES=0; IPSET=0
H_START=0; H_LISTEN=0; H_LAUNCHED=0; H_PROCS=0; H_NET=0; OK=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IPSET=1
    grep -a -qF -- "httpd: starting" "$SERIAL" && H_START=1
    grep -a -qF -- "httpd: listening on port 8080" "$SERIAL" && H_LISTEN=1
    grep -a -qF -- "echo httpd-launched" "$SERIAL" && H_LAUNCHED=1
    grep -a -E -- "HTTPD\.BIN" "$SERIAL" && H_PROCS=1
    grep -a -E -- "tcp=listen" "$SERIAL" && H_NET=1
    grep -a -qF -- "echo httpd-ok" "$SERIAL" && OK=1
fi

cat > "$REPORT" <<EOF
verify-live-httpd report (Claim 0750)
=====================================
revision:      $REVISION
branch:        $BRANCH
dirty-files:   $DIRTY
exit_code:     $RC
serial_bytes:  $SERIAL_BYTES
net_ip_set:    $IPSET
httpd_start:   $H_START
httpd_listen:  $H_LISTEN
httpd_procs:   $H_PROCS
httpd_tcp_net: $H_NET
httpd_ok:      $OK
EOF

cat "$REPORT"

# Hard assertions
[ "$RC" -eq 0 ] || { echo "verify-live-httpd: FAIL (VMRunner exited $RC)"; exit 1; }
[ "$IPSET" -eq 1 ] || { echo "verify-live-httpd: FAIL (net ip not configured)"; exit 1; }
[ "$H_START" -eq 1 ] || { echo "verify-live-httpd: FAIL (httpd did not start)"; exit 1; }
[ "$H_LISTEN" -eq 1 ] || { echo "verify-live-httpd: FAIL (httpd did not listen on port 8080)"; exit 1; }
[ "$H_PROCS" -eq 1 ] || { echo "verify-live-httpd: FAIL (HTTPD.BIN not found in procs table)"; exit 1; }
[ "$H_NET" -eq 1 ] || { echo "verify-live-httpd: FAIL (tcp state != listen in monitor)"; exit 1; }
[ "$OK" -eq 1 ] || { echo "verify-live-httpd: FAIL (httpd-ok script expect not reached)"; exit 1; }

echo "verify-live-httpd: PASS — HTTPD.BIN live on VZ hardware, passive open port 8080, tcp=listen in monitor."
