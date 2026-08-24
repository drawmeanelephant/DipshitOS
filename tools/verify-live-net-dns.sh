#!/usr/bin/env bash
#
# verify-live-net-dns.sh -- claim 7566 (milestone twelve, card N2, Issue #149)
# class-B gate: the RFC 1035 bounded DNS client live on real VZ hardware —
# standard A-record queries over UDP targeting DNS port 53, response parsing,
# domain decompression, and address extraction.
#
# Mechanism:
#   1. `net ip 10.0.0.1` + `net arp 10.0.0.2` sets static IP and resolves server MAC.
#   2. `net dns example.com 10.0.0.2` -> queries DNS server at 10.0.0.2:53,
#      receives response with A-record 93.184.216.34 -> prints `net dns: example.com -> 93.184.216.34`.
#   3. `net dns myhost.local 10.0.0.2` -> queries DNS server, receives 10.0.0.2 ->
#      prints `net dns: myhost.local -> 10.0.0.2`.
#   4. `net` prints DNS statistics `dns=resolved,q=2,r=2,err=0,timeout=0`.
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# log, capture, and scripts under $RUN_DIR. Set DIPSHIT_GATE_SUFFIX=_alt
# for distinct canonical evidence names; DIPSHIT_KEEP_RUN=1 keeps the
# scratch dir.

GATE_LOG="$(art live-net-dns-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-net-dns-report.txt)"

echo "=== verify-live-net-dns: claim 7566 — bounded DNS client live on VZ (RFC 1035 A-record queries, response parsing, address extraction) ==="

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
gate_begin live-net-dns
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net dns example.com 10.0.0.2
net dns myhost.local 10.0.0.2
net
echo net-dns-ok
EOF

# --- the run ----------------------------------------------------------------
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --net "$RUN_DIR/cap.bin" \
    --net-arp-respond 10.0.0.2 --net-dns-respond 10.0.0.2:53 \
    --script "$RUN_DIR/script-1.txt" \
    --script-expect 'net-dns-ok' --timeout 60 \
    > "$(art live-net-dns-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-net-dns-serial.log)" || true

# --- assertions -------------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
SERIAL_BYTES=0; IPSET=0
DNS_EXAMPLE=0; DNS_LOCAL=0; DNS_COUNTERS=0; OK=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IPSET=1
    grep -a -qF -- "net dns: example.com -> 93.184.216.34" "$SERIAL" && DNS_EXAMPLE=1
    grep -a -qF -- "net dns: myhost.local -> 10.0.0.2" "$SERIAL" && DNS_LOCAL=1
    grep -a -qF -- "dns=resolved,q=2,r=2,err=0,timeout=0" "$SERIAL" && DNS_COUNTERS=1
    grep -a -qF -- "echo net-dns-ok" "$SERIAL" && OK=1
fi

ANETDNS1=0; ANETDNS2=0; ARUNNER=0
if [ -f "$(art live-net-dns-run.txt)" ]; then
    grep -a -qF -- "NET-DNS: answered the guest's DNS query for 'example.com'" "$(art live-net-dns-run.txt)" && ANETDNS1=1
    grep -a -qF -- "NET-DNS: answered the guest's DNS query for 'myhost.local'" "$(art live-net-dns-run.txt)" && ANETDNS2=1
    grep -a -qF -- "net-dns-respond: ENABLED" "$(art live-net-dns-run.txt)" && ARUNNER=1
fi

cat > "$REPORT" <<EOF
=== verify-live-net-dns report ===
revision:        $REVISION
branch:          $BRANCH
dirty-files:     $DIRTY
runner_rc:       $RC
serial_bytes:    $SERIAL_BYTES
net_ip_set:      $IPSET
dns_example:     $DNS_EXAMPLE
dns_local:       $DNS_LOCAL
dns_counters:    $DNS_COUNTERS
responder_dns1:  $ANETDNS1
responder_dns2:  $ANETDNS2
runner_enabled:  $ARUNNER
EOF

cat "$REPORT"

# Final gate evaluation
if [ "$RC" -eq 0 ] && [ "$IPSET" -eq 1 ] && [ "$DNS_EXAMPLE" -eq 1 ] && \
   [ "$DNS_LOCAL" -eq 1 ] && [ "$DNS_COUNTERS" -eq 1 ] && \
   [ "$ANETDNS1" -eq 1 ] && [ "$ANETDNS2" -eq 1 ] && [ "$ARUNNER" -eq 1 ]; then
    echo "=== verify-live-net-dns: PASS ==="
    exit 0
else
    echo "=== verify-live-net-dns: FAIL ==="
    exit 1
fi
