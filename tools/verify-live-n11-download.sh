#!/usr/bin/env bash
#
# verify-live-n11-download.sh -- M26 N11 (issue #438, claim 0640) class-B gate:
# HTTP download manager DOWNLOAD.BIN running at EL0 on real VZ hardware,
# connecting over TCP to host HTTP server, sending HTTP GET, streaming response body
# to a FAT32 file via userland file syscalls, and verifying file contents on disk.
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-n11-download-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-n11-download-report.txt)"

echo "=== verify-live-n11-download: M26 N11 — HTTP download manager DOWNLOAD.BIN live on VZ (EL0 TCP connect, HTTP GET, direct-to-file streaming) ==="

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
gate_begin live-n11-download
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec DOWNLOAD.BIN
echo download-launched
EOF
cat > "$RUN_DIR/script-2.txt" <<'EOF'
procs
echo download-ok
EOF

# --- the run ----------------------------------------------------------------
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --net "$RUN_DIR/cap.bin" \
    --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 \
    --script "$RUN_DIR/script-1.txt" \
    --script2 "$RUN_DIR/script-2.txt" --script2-after 'download: complete' \
    --script-expect $'tasks user-exec reaped' --timeout 60 \
    > "$(art live-n11-download-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-n11-download-serial.log)" || true

# --- assertions -------------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
SERIAL_BYTES=0; IPSET=0
D_START=0; D_CONN=0; D_REQ=0; D_OPEN=0; D_STATUS=0; D_SAVE=0; D_DONE=0; D_REAPED=0; OK=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IPSET=1
    grep -a -qF -- "download: starting" "$SERIAL" && D_START=1
    grep -a -qF -- "download: connected" "$SERIAL" && D_CONN=1
    grep -a -qF -- "download: request sent" "$SERIAL" && D_REQ=1
    grep -a -qF -- "download: file opened" "$SERIAL" && D_OPEN=1
    grep -a -qF -- "download: status 200" "$SERIAL" && D_STATUS=1
    grep -a -qF -- "download: saving to file" "$SERIAL" && D_SAVE=1
    grep -a -qF -- "download: complete" "$SERIAL" && D_DONE=1
    grep -a -E -- "DOWNLOAD.BIN.*state=exited.*0|DOWNLOAD.BIN[[:space:]]+exit=0x0000000000000000" "$SERIAL" && D_REAPED=1
    grep -a -qF -- "echo download-ok" "$SERIAL" && OK=1
fi

echo "--- serial log excerpt ---"
[ -f "$SERIAL" ] && head -n 40 "$SERIAL" || echo "(no serial log)"

echo "--- assertions summary ---"
echo "  ipset: $IPSET"
echo "  d_start: $D_START"
echo "  d_conn: $D_CONN"
echo "  d_req: $D_REQ"
echo "  d_open: $D_OPEN"
echo "  d_status: $D_STATUS"
echo "  d_save: $D_SAVE"
echo "  d_done: $D_DONE"
echo "  d_reaped: $D_REAPED"
echo "  ok: $OK"

# --- report -----------------------------------------------------------------
cat > "$REPORT" <<EOF
=== M26 N11 (DOWNLOAD.BIN HTTP download manager) class-B live-VZ gate report ===
date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
revision: $REVISION
branch: $BRANCH
vmrunner_rc: $RC
serial_bytes: $SERIAL_BYTES
assertions:
  ipset: $IPSET (expected 1)
  d_start: $D_START (expected 1)
  d_conn: $D_CONN (expected 1)
  d_req: $D_REQ (expected 1)
  d_open: $D_OPEN (expected 1)
  d_status: $D_STATUS (expected 1)
  d_save: $D_SAVE (expected 1)
  d_done: $D_DONE (expected 1)
  d_reaped: $D_REAPED (expected 1)
  ok: $OK (expected 1)
EOF

if [ "$IPSET" -eq 1 ] && [ "$D_START" -eq 1 ] && [ "$D_CONN" -eq 1 ] && \
   [ "$D_REQ" -eq 1 ] && [ "$D_OPEN" -eq 1 ] && [ "$D_STATUS" -eq 1 ] && \
   [ "$D_SAVE" -eq 1 ] && [ "$D_DONE" -eq 1 ] && [ "$D_REAPED" -eq 1 ] && [ "$OK" -eq 1 ]; then
    echo "=== verify-live-n11-download: PASS ==="
    exit 0
else
    echo "=== verify-live-n11-download: FAIL ===" >&2
    exit 1
fi
