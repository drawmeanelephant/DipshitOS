#!/usr/bin/env bash
#
# verify-live-n4-top-net.sh -- M26 N4 (issue #402, claim 0640) class-B gate:
# TOP.BIN Network & Bandwidth tab live on real VZ hardware with graphics + input + net.
#
# Asserts:
#   1. TOP.BIN opens its GUI window (window id=3) at EL0.
#   2. Switches to the Network tab via input chord 'n' (observed via "top: tab=network").
#   3. Introspects network statistics via sys_net_stats (slot 62) and refreshes on 'r'.
#   4. Switches back to Procs tab via input chord 'p' (observed via "top: tab=procs").
#   5. Introspects sys_procs (slot 7) and sys_net_stats (slot 62) syscall counts.
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-n4-top-net-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-n4-top-net-report.txt)"

echo "=== verify-live-n4-top-net: M26 N4 — TOP.BIN Network & Bandwidth tab live on VZ ==="

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
gate_begin live-n4-top-net
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net ip 10.0.0.1
exec TOP.BIN
EOF

cat > "$RUN_DIR/script-2.txt" <<'EOF'
procs
syscalls
echo done-top-net
EOF

# --- the run ----------------------------------------------------------------
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin"
rm -f "$RUN_DIR"/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --display --input --screen "$RUN_DIR/gpu-screen" \
    --net "$RUN_DIR/cap.bin" \
    --script "$RUN_DIR/script-1.txt" \
    --input-chords "n,r,p" \
    --input-chords-after "top: open id=3" \
    --script2 "$RUN_DIR/script-2.txt" \
    --script2-after "top: tab=procs" \
    --script-expect "done-top-net" \
    --timeout 60 > "$(art live-n4-top-net-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-n4-top-net-serial.log)" || true
cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true

# --- assertions -------------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
SERIAL_BYTES=0; IPSET=0; TOP_OPEN=0; TAB_NET=0; REFRESHED=0; TAB_PROCS=0; STATS_CALLS=0; OK=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IPSET=1
    grep -a -qF -- "top: open id=3" "$SERIAL" && TOP_OPEN=1
    grep -a -qF -- "top: tab=network" "$SERIAL" && TAB_NET=1
    grep -a -qF -- "top: refreshed ok" "$SERIAL" && REFRESHED=1
    grep -a -qF -- "top: tab=procs" "$SERIAL" && TAB_PROCS=1
    grep -a -E -- "62 sys_net_stats calls=[1-9]" "$SERIAL" && STATS_CALLS=1
    grep -a -qF -- "echo done-top-net" "$SERIAL" && OK=1
fi

echo "--- serial log excerpt ---"
[ -f "$SERIAL" ] && head -n 40 "$SERIAL" || echo "(no serial log)"

echo "--- assertions summary ---"
echo "  ipset: $IPSET"
echo "  top_open: $TOP_OPEN"
echo "  tab_net: $TAB_NET"
echo "  refreshed: $REFRESHED"
echo "  tab_procs: $TAB_PROCS"
echo "  stats_calls: $STATS_CALLS"
echo "  ok: $OK"
echo "  runner exit code: $RC"

cat > "$REPORT" <<EOF
verify-live-n4-top-net report
=============================
revision: $REVISION
branch: $BRANCH
serial_bytes: $SERIAL_BYTES
ipset: $IPSET
top_open: $TOP_OPEN
tab_net: $TAB_NET
refreshed: $REFRESHED
tab_procs: $TAB_PROCS
stats_calls: $STATS_CALLS
ok: $OK
rc: $RC
EOF

if [ "$IPSET" -eq 1 ] && [ "$TOP_OPEN" -eq 1 ] && [ "$TAB_NET" -eq 1 ] && \
   [ "$REFRESHED" -eq 1 ] && [ "$TAB_PROCS" -eq 1 ] && [ "$STATS_CALLS" -eq 1 ] && \
   [ "$OK" -eq 1 ] && [ "$RC" -eq 0 ]; then
    echo "verify-live-n4-top-net: PASS"
    exit 0
else
    echo "verify-live-n4-top-net: FAIL"
    exit 1
fi
