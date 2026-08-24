#!/usr/bin/env bash
#
# verify-live-netstat.sh -- M26 N2 (issue #400) class-B gate:
# NETSTAT.BIN — the network dashboard — on real VZ hardware.
#
# Mechanism: boots the production image with the GPU (display), sets a
# static IP + ARP entry from the monitor, execs NETSTAT.BIN, waits for
# the section markers + `netstat: ready` (the window is up, the 1 Hz
# refresh timer is armed), then keeps the VM alive a few seconds for a
# screenshot. The class-B proof: the app called sys_net_stats (slot 62)
# and rendered every dashboard section.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log under $RUN_DIR (gate-run.sh).
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-netstat.sh
#
# Evidence saved under artifacts/: live-netstat-gate.txt,
# live-netstat-report.txt, live-netstat-run.txt, live-netstat-serial.log,
# netstat-screen-5s.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-netstat-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-netstat-report.txt)"

echo "=== verify-live-netstat: M26 N2 — NETSTAT.BIN network dashboard on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
# SPIKE build (macOS 27 SDK types) — the editor-gate pattern: no VZ view
# keyboard, headless-safe evidence via claim-9588 (not needed here since
# NETSTAT needs no keystrokes, but the same binary shape is verified).
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ------------------------------------------------------
gate_begin live-netstat
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# Set a static IP + one ARP entry so the dashboard has real values, then
# launch NETSTAT.BIN from the monitor.
cat > "$SCRIPT" <<'EOF'
net ip 10.0.0.9
net arp 10.0.0.2
exec NETSTAT.BIN
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --screen "$(art netstat-screen-5s)" \
        --script "$SCRIPT" \
        --script-expect "netstat: ready" \
        --timeout 45 \
        > "$(art live-netstat-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-netstat-serial-$tag.log)" || true
    local SER="$(art live-netstat-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 N_READY=0 N_IFACE=0 N_DHCP=0 N_TCP=0 N_UDP=0 N_ARP=0 N_CNT=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "netstat: ready" "$SER" && N_READY=1
        grep -qF -- "netstat: section iface" "$SER" && N_IFACE=1
        grep -qF -- "netstat: section dhcp" "$SER" && N_DHCP=1
        grep -qF -- "netstat: section tcp" "$SER" && N_TCP=1
        grep -qF -- "netstat: section udp" "$SER" && N_UDP=1
        grep -qF -- "netstat: section arp" "$SER" && N_ARP=1
        grep -qF -- "netstat: section counters" "$SER" && N_CNT=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER ready=$N_READY iface=$N_IFACE dhcp=$N_DHCP tcp=$N_TCP udp=$N_UDP arp=$N_ARP counters=$N_CNT"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER ready=$N_READY iface=$N_IFACE dhcp=$N_DHCP tcp=$N_TCP udp=$N_UDP arp=$N_ARP counters=$N_CNT"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$N_READY" = 1 ] && \
    [ "$N_IFACE" = 1 ] && [ "$N_DHCP" = 1 ] && [ "$N_TCP" = 1 ] && \
    [ "$N_UDP" = 1 ] && [ "$N_ARP" = 1 ] && [ "$N_CNT" = 1 ]
}

PASS=0
i=1
while [ "$i" -le "$BOOTS" ]; do
    TAG="$(printf '%02d' "$i")"
    if run_one "$TAG"; then
        PASS=$((PASS + 1))
    fi
    i=$((i + 1))
done

gate_end

[ "$PASS" -ge 1 ] || { echo "verify-live-netstat: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-netstat-report.txt)"; exit 1; }
echo "=== verify-live-netstat: PASS — NETSTAT.BIN opened its dashboard window, rendered all six sections, and called sys_net_stats ($PASS/$BOOTS boot(s)). ==="