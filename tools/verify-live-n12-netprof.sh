#!/usr/bin/env bash
#
# verify-live-n12-netprof.sh -- M26 N12 (issue #439, claim 7635) class-B gate:
# NETPROF.BIN running at EL0 on real VZ hardware, managing network configuration
# profiles and persisting to /host/NET.TXT (M34 HF6 re-point; the /data
# volume is gone), cleanly exiting status 0.
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-n12-netprof-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-n12-netprof-report.txt)"

echo "=== verify-live-n12-netprof: M26 N12 — Network profile manager NETPROF.BIN live on VZ (EL0 profiles, /host/NET.TXT persistence, clean exit) ==="

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
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-n12-netprof
gate_seed_share
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
exec NETPROF.BIN
EOF
cat > "$RUN_DIR/script-2.txt" <<'EOF'
cat NET.TXT
procs
echo netprof-ok
EOF

# --- the run ----------------------------------------------------------------
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --net "$RUN_DIR/cap.bin" \
    --script "$RUN_DIR/script-1.txt" \
    --script2 "$RUN_DIR/script-2.txt" --script2-after 'netprof: complete' \
    --script-expect $'echo netprof-ok' --timeout 60 \
    > "$(art live-n12-netprof-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-n12-netprof-serial.log)" || true

# --- assertions -------------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
SERIAL_BYTES=0
P_START=0; P_HDR=0; P_DEF=0; P_HOME=0; P_SAVE=0; P_DONE=0; P_TYPE=0; P_REAPED=0; OK=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "netprof: starting" "$SERIAL" && P_START=1
    grep -a -qF -- "--- network profiles ---" "$SERIAL" && P_HDR=1
    grep -a -qF -- "profile default: ip=10.0.0.1 gw=10.0.0.2 dns=1.1.1.1" "$SERIAL" && P_DEF=1
    grep -a -qF -- "profile home: ip=192.168.1.50 gw=192.168.1.1 dns=8.8.8.8" "$SERIAL" && P_HOME=1
    grep -a -qF -- "netprof: saved to /host/NET.TXT" "$SERIAL" && P_SAVE=1
    grep -a -qF -- "netprof: complete" "$SERIAL" && P_DONE=1
    grep -a -qF -- "default=10.0.0.1,10.0.0.2,1.1.1.1" "$SERIAL" && P_TYPE=1
    grep -a -E -- "procs NETPROF\.BIN exited status=0|NETPROF.*state=exited.*0" "$SERIAL" && P_REAPED=1
    grep -a -qF -- "echo netprof-ok" "$SERIAL" && OK=1
fi

echo "--- serial log excerpt ---"
[ -f "$SERIAL" ] && head -n 40 "$SERIAL" || echo "(no serial log)"

echo "--- assertions summary ---"
echo "  p_start: $P_START"
echo "  p_hdr: $P_HDR"
echo "  p_def: $P_DEF"
echo "  p_home: $P_HOME"
echo "  p_save: $P_SAVE"
echo "  p_done: $P_DONE"
echo "  p_type: $P_TYPE"
echo "  p_reaped: $P_REAPED"
echo "  ok: $OK"

TOTAL=$((P_START + P_HDR + P_DEF + P_HOME + P_SAVE + P_DONE + P_TYPE + P_REAPED + OK))

cat > "$REPORT" <<EOF
test: verify-live-n12-netprof (M26 N12 — NETPROF.BIN live on VZ)
revision: $REVISION
branch: $BRANCH
dirty_files: $DIRTY
runner_exit_code: $RC
serial_log_bytes: $SERIAL_BYTES
assertions_passed: $TOTAL/9
  p_start: $P_START
  p_hdr: $P_HDR
  p_def: $P_DEF
  p_home: $P_HOME
  p_save: $P_SAVE
  p_done: $P_DONE
  p_type: $P_TYPE
  p_reaped: $P_REAPED
  ok: $OK
status: $([ "$TOTAL" -eq 9 ] && echo PASS || echo FAIL)
EOF

if [ "$TOTAL" -ne 9 ]; then
    echo "=== verify-live-n12-netprof: FAIL ($TOTAL/9 assertions passed) ==="
    exit 1
fi

echo "=== verify-live-n12-netprof: PASS ==="
exit 0
