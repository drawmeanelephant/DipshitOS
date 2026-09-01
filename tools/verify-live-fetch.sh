#!/usr/bin/env bash
#
# verify-live-fetch.sh -- claim 5416 (milestone twelve, card N3, Issue #150)
# class-B gate: the capstone HTTP/1.0 client FETCH.BIN running at EL0 on
# real VZ hardware, establishing a TCP connection to the host on port 80,
# sending a GET request, receiving the HTTP response, printing the stream
# to the serial console, and cleanly exiting status 42.
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# log, capture, and scripts under $RUN_DIR. Set VIRELAI_GATE_SUFFIX=_alt
# for distinct canonical evidence names; VIRELAI_KEEP_RUN=1 keeps the
# scratch dir.

GATE_LOG="$(art live-fetch-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-fetch-report.txt)"

echo "=== verify-live-fetch: claim 5416 — HTTP/1.0 client FETCH.BIN live on VZ (EL0 TCP connect, HTTP GET, response streaming, clean close) ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-fetch
gate_seed_share
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-1.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec FETCH.BIN
echo fetch-launched
EOF
cat > "$RUN_DIR/script-2.txt" <<'EOF'
procs
echo fetch-ok
EOF

# --- the run ----------------------------------------------------------------
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --net "$RUN_DIR/cap.bin" \
    --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 \
    --script "$RUN_DIR/script-1.txt" \
    --script2 "$RUN_DIR/script-2.txt" --script2-after 'fetch: done' \
    --script-expect $'tasks user-exec reaped' --timeout 90 \
    > "$(art live-fetch-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-fetch-serial.log)" || true

# --- assertions -------------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
SERIAL_BYTES=0; IPSET=0
F_START=0; F_CONN=0; F_REQ=0; F_HTTP200=0; F_BODY=0; F_DONE=0; F_EXIT42=0; OK=0
# M26 N3 (issue #401): the terminal display separates headers and body.
F_HDRS=0; F_HDRSEC=0; F_BODYSEC=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IPSET=1
    grep -a -qF -- "fetch: starting" "$SERIAL" && F_START=1
    grep -a -qF -- "fetch: connected" "$SERIAL" && F_CONN=1
    grep -a -qF -- "fetch: request sent" "$SERIAL" && F_REQ=1
    grep -a -qF -- "HTTP/1.0 200 OK" "$SERIAL" && F_HTTP200=1
    grep -a -qF -- "Hello from VirelaiOS Host!" "$SERIAL" && F_BODY=1
    grep -a -qF -- "fetch: done" "$SERIAL" && F_DONE=1
    grep -a -qF -- "fetch: headers" "$SERIAL" && F_HDRS=1
    grep -a -qF -- "--- response headers ---" "$SERIAL" && F_HDRSEC=1
    grep -a -qF -- "--- response body ---" "$SERIAL" && F_BODYSEC=1
    grep -a -E -- "FETCH.BIN[[:space:]]+exit=0x000000000000002a|FETCH.BIN.*state=exited.*42|FETCH.BIN.*exit=0x000000000000002a" "$SERIAL" && F_EXIT42=1
    grep -a -qF -- "echo fetch-ok" "$SERIAL" && OK=1
    # N3 ordering: the headers section must come BEFORE the body section.
    HDRPOS=$(grep -a -boF -- "--- response headers ---" "$SERIAL" | head -1 | cut -d: -f1)
    BODYPOS=$(grep -a -boF -- "--- response body ---" "$SERIAL" | head -1 | cut -d: -f1)
    if [ -n "$HDRPOS" ] && [ -n "$BODYPOS" ] && [ "$BODYPOS" -gt "$HDRPOS" ]; then F_ORDER=1; fi
fi

ATCP_SYN=0; ATCP_HTTP=0; ARUNNER=0
if [ -f "$(art live-fetch-run.txt)" ]; then
    grep -a -qF -- "NET-TCP: answered the guest's SYN" "$(art live-fetch-run.txt)" && ATCP_SYN=1
    grep -a -qF -- "NET-TCP: answered the guest's HTTP request with 200 OK" "$(art live-fetch-run.txt)" && ATCP_HTTP=1
    grep -a -qF -- "net-tcp-respond: ENABLED" "$(art live-fetch-run.txt)" && ARUNNER=1
fi

cat > "$REPORT" <<EOF
=== verify-live-fetch report ===
revision:           $REVISION
branch:             $BRANCH
dirty-files:        $DIRTY
runner_rc:          $RC
serial_bytes:       $SERIAL_BYTES
net_ip_set:         $IPSET
fetch_starting:     $F_START
fetch_connected:    $F_CONN
fetch_req_sent:     $F_REQ
fetch_http200:      $F_HTTP200
fetch_body:         $F_BODY
fetch_done:         $F_DONE
fetch_exit42:       $F_EXIT42
fetch_headers:      $F_HDRS
fetch_hdrsec:       $F_HDRSEC
fetch_bodsec:       $F_BODYSEC
fetch_hdr_before_body: $F_ORDER
responder_syn:      $ATCP_SYN
responder_http:     $ATCP_HTTP
runner_enabled:     $ARUNNER
EOF

cat "$REPORT"

# Final gate evaluation
if [ "$RC" -eq 0 ] && [ "$IPSET" -eq 1 ] && [ "$F_START" -eq 1 ] && \
   [ "$F_CONN" -eq 1 ] && [ "$F_REQ" -eq 1 ] && [ "$F_HTTP200" -eq 1 ] && \
   [ "$F_BODY" -eq 1 ] && [ "$F_DONE" -eq 1 ] && [ "$F_EXIT42" -eq 1 ] && \
   [ "$F_HDRS" -eq 1 ] && [ "$F_HDRSEC" -eq 1 ] && [ "$F_BODYSEC" -eq 1 ] && [ "$F_ORDER" -eq 1 ] && \
   [ "$ATCP_SYN" -eq 1 ] && [ "$ATCP_HTTP" -eq 1 ] && [ "$ARUNNER" -eq 1 ]; then
    echo "=== verify-live-fetch: PASS ==="
    exit 0
else
    echo "=== verify-live-fetch: FAIL ==="
    exit 1
fi
