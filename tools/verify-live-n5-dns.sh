#!/usr/bin/env bash
#
# verify-live-n5-dns.sh -- M26 N5 (issue #403, claim 0640) class-B gate:
# Standalone userland DNS query tool (DNS.BIN) running at EL0 on real VZ
# hardware, sending RFC 1035 UDP queries via sys_udp_send (slot 10), receiving
# DNS responses via sys_udp_recv (slot 11) from the host runner
# (--net-dns-respond 10.0.0.2:53), decoding the A-record answer, and exiting 0.
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-n5-dns-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-n5-dns-report.txt)"

echo "=== verify-live-n5-dns: M26 N5 — DNS.BIN RFC 1035 UDP client live on VZ ==="

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
gate_begin live-n5-dns
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec DNS.BIN example.com 10.0.0.2
echo dns-launched
EOF
cat > "$RUN_DIR/script-2.txt" <<'EOF'
procs
echo dns-ok
EOF

# --- the run ----------------------------------------------------------------
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --net "$RUN_DIR/cap.bin" \
    --net-arp-respond 10.0.0.2 --net-dns-respond 10.0.0.2 \
    --script "$RUN_DIR/script-1.txt" \
    --script2 "$RUN_DIR/script-2.txt" --script2-after 'dns: status=ok' \
    --script-expect $'tasks user-exec reaped' --timeout 60 \
    > "$(art live-n5-dns-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-n5-dns-serial.log)" || true

# --- assertions -------------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
SERIAL_BYTES=0; IPSET=0; ARPSET=0
D_QUERY=0; D_ANS=0; D_STATUS=0; D_REAPED=0; OK=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IPSET=1
    grep -a -E -- "net arp: (request for|resolved)" "$SERIAL" && ARPSET=1
    grep -a -qF -- "DNS query for example.com via 10.0.0.2:53" "$SERIAL" && D_QUERY=1
    grep -a -qF -- "Answer: example.com -> 93.184.216.34" "$SERIAL" && D_ANS=1
    grep -a -qF -- "dns: status=ok" "$SERIAL" && D_STATUS=1
    grep -a -E -- "DNS.BIN.*state=exited.*0|DNS.BIN[[:space:]]+exit=0x0000000000000000" "$SERIAL" && D_REAPED=1
    grep -a -qF -- "echo dns-ok" "$SERIAL" && OK=1
fi

echo "--- serial log excerpt ---"
[ -f "$SERIAL" ] && head -n 40 "$SERIAL" || echo "(no serial log)"

echo "--- assertions summary ---"
echo "  ipset: $IPSET"
echo "  arpset: $ARPSET"
echo "  d_query: $D_QUERY"
echo "  d_ans: $D_ANS"
echo "  d_status: $D_STATUS"
echo "  d_reaped: $D_REAPED"
echo "  ok: $OK"
echo "  runner exit code: $RC"

cat > "$REPORT" <<EOF
verify-live-n5-dns report
=========================
revision: $REVISION
branch: $BRANCH
serial_bytes: $SERIAL_BYTES
ipset: $IPSET
arpset: $ARPSET
d_query: $D_QUERY
d_ans: $D_ANS
d_status: $D_STATUS
d_reaped: $D_REAPED
ok: $OK
rc: $RC
EOF

if [ "$IPSET" -eq 1 ] && [ "$ARPSET" -eq 1 ] && [ "$D_QUERY" -eq 1 ] && \
   [ "$D_ANS" -eq 1 ] && [ "$D_STATUS" -eq 1 ] && [ "$D_REAPED" -eq 1 ] && \
   [ "$OK" -eq 1 ] && [ "$RC" -eq 0 ]; then
    echo "verify-live-n5-dns: PASS"
    exit 0
else
    echo "verify-live-n5-dns: FAIL"
    exit 1
fi
