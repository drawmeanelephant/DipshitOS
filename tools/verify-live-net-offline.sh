#!/usr/bin/env bash
#
# verify-live-net-offline.sh -- M26 N13+N14 (march-m26, claim 8852)
# class-B gate: the network preflight in PING.BIN / FETCH.BIN, live on VZ.
#
# Run A (offline boot — NO --net flag, no net device attached):
#   - exec PING.BIN -c 3 10.0.0.2  -> ONE "ping: offline — no IP address"
#     line, exit status 2, and NO per-ping lines / no statistics footer
#     (the fast exit — bounded poll never entered).
#   - exec FETCH.BIN               -> "fetch: offline — no IP address",
#     exit status 3, no "fetch: connected".
# Run B (no-route boot — --net attached, own IP set, ARP table EMPTY):
#   - exec PING.BIN -c 1 10.0.0.2  -> "ping: no route to 10.0.0.2",
#     exit status 3 (fast — the send path is never entered).
# Run C (online control — --net + arp/icmp/tcp responders, the N1/N3
# shapes): the preflight passes (.ready) and the normal paths still run:
#   - PING.BIN pings + statistics footer (the N1 assertions)
#   - FETCH.BIN connects and fetches (the N3 assertions)
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-net-offline-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-net-offline-report.txt)"

echo "=== verify-live-net-offline: M26 N13+N14 — network preflight in PING.BIN/FETCH.BIN live on VZ (offline fast-exit, no-route fast-exit, online control) ==="

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

RUNNER=host/vm-runner/.build/release/VMRunner

assert_count=0
fail_count=0
check() { # check <name> <actual> <want>
    assert_count=$((assert_count + 1))
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1 (got '$2' want '$3')"
        fail_count=$((fail_count + 1))
    fi
}

# =============================================================================
# Run A — offline boot (no --net): both apps exit fast with the diagnosis
# =============================================================================
gate_begin live-net-offline-a
echo "--- run A: offline boot (no net device) ---"

cat > "$RUN_DIR/script-1.txt" <<'SCRIPT1'
exec PING.BIN -c 3 10.0.0.2
exec FETCH.BIN
echo both-launched
SCRIPT1
cat > "$RUN_DIR/script-2.txt" <<'SCRIPT2'
echo offline-ok
SCRIPT2

rm -f "$RUN_DIR/vm-serial.log" "$RUN_DIR/efi-vars.bin"
set +e
"$RUNNER" "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --script "$RUN_DIR/script-1.txt" \
    --script2 "$RUN_DIR/script-2.txt" --script2-after 'offline — no IP address' \
    --script-expect $'FETCH.BIN exited status=3' --timeout 90 \
    > "$(art live-net-offline-a-run.txt)" 2>&1
RC_A=$?
set -e
cp "$RUN_DIR/vm-serial.log" "$(art live-net-offline-a-serial.log)"

SERIAL_A="$RUN_DIR/vm-serial.log"
A_PING_OFFLINE=0; A_PING_EXIT=0; A_PING_NO_STATS=0; A_FETCH_OFFLINE=0; A_FETCH_EXIT=0; A_FETCH_NO_CONN=0; A_OK=0
if [ -f "$SERIAL_A" ]; then
    N_OFFLINE=$(grep -a -cF -- 'ping: offline — no IP address' "$SERIAL_A" || true)
    [ "$N_OFFLINE" -ge 1 ] && A_PING_OFFLINE=1
    N_PING_EXIT=$(grep -a -cE -- 'PING\.BIN exited status=2([^0-9]|$)|exit=0x0000000000000002' "$SERIAL_A" || true)
    [ "$N_PING_EXIT" -ge 1 ] && A_PING_EXIT=1
    # Fast exit: the bounded poll never ran — no per-ping reply lines, no footer.
    N_STATS=$(grep -a -cF -- 'ping statistics' "$SERIAL_A" || true)
    [ "$N_STATS" -eq 0 ] && A_PING_NO_STATS=1
    grep -a -qF -- 'fetch: offline — no IP address' "$SERIAL_A" && A_FETCH_OFFLINE=1
    N_FETCH_EXIT=$(grep -a -cE -- 'FETCH\.BIN exited status=3([^0-9]|$)|exit=0x0000000000000003' "$SERIAL_A" || true)
    [ "$N_FETCH_EXIT" -ge 1 ] && A_FETCH_EXIT=1
    grep -a -qF -- 'fetch: connected' "$SERIAL_A" || A_FETCH_NO_CONN=1
    grep -a -qF -- 'echo offline-ok' "$SERIAL_A" && A_OK=1
fi
check "A: ping offline message"        "$A_PING_OFFLINE" 1
check "A: ping exit status 2"          "$A_PING_EXIT"    1
check "A: ping no statistics (fast)"   "$A_PING_NO_STATS" 1
check "A: fetch offline message"       "$A_FETCH_OFFLINE" 1
check "A: fetch exit status 3"         "$A_FETCH_EXIT"   1
check "A: fetch never connected"       "$A_FETCH_NO_CONN" 1
check "A: shell responsive"            "$A_OK"           1
gate_end

# =============================================================================
# Run B — no-route boot (--net attached, IP set, ARP table empty)
# =============================================================================
gate_begin live-net-offline-b
echo "--- run B: no-route boot (net device, ip set, no arp entry) ---"

cat > "$RUN_DIR/script-1.txt" <<'EOF'
net ip 10.0.0.1
exec PING.BIN -c 1 10.0.0.2
echo ping-noroute-launched
EOF
cat > "$RUN_DIR/script-2.txt" <<'EOF'
echo noroute-ok
EOF

rm -f "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin" "$RUN_DIR/efi-vars.bin"
set +e
"$RUNNER" "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --net "$RUN_DIR/cap.bin" \
    --script "$RUN_DIR/script-1.txt" \
    --script2 "$RUN_DIR/script-2.txt" --script2-after 'ping-noroute-launched' \
    --script-expect $'PING.BIN exited status=3' --timeout 90 \
    > "$(art live-net-offline-b-run.txt)" 2>&1
RC_B=$?
set -e
cp "$RUN_DIR/vm-serial.log" "$(art live-net-offline-b-serial.log)"

SERIAL_B="$RUN_DIR/vm-serial.log"
B_NOROUTE=0; B_EXIT=0; B_IP_SET=0; B_NO_STATS=0; B_OK=0
if [ -f "$SERIAL_B" ]; then
    grep -a -qF -- 'net ip: ip=10.0.0.1' "$SERIAL_B" && B_IP_SET=1
    grep -a -qF -- 'ping: no route to 10.0.0.2' "$SERIAL_B" && B_NOROUTE=1
    N_B_EXIT=$(grep -a -cE -- 'PING\.BIN exited status=3([^0-9]|$)|exit=0x0000000000000003' "$SERIAL_B" || true)
    [ "$N_B_EXIT" -ge 1 ] && B_EXIT=1
    N_B_STATS=$(grep -a -cF -- 'ping statistics' "$SERIAL_B" || true)
    [ "$N_B_STATS" -eq 0 ] && B_NO_STATS=1
    grep -a -qF -- 'echo noroute-ok' "$SERIAL_B" && B_OK=1
fi
check "B: net ip set"                   "$B_IP_SET"   1
check "B: ping no-route message"        "$B_NOROUTE"  1
check "B: ping exit status 3"           "$B_EXIT"     1
check "B: ping no statistics (fast)"    "$B_NO_STATS" 1
check "B: shell responsive"             "$B_OK"       1
gate_end

# =============================================================================
# Run C — online control (--net + responders): normal paths unaffected
# =============================================================================
gate_begin live-net-offline-c
echo "--- run C: online control (net + arp/icmp/tcp responders) ---"

cat > "$RUN_DIR/script-1.txt" <<'SCRIPT1'
net ip 10.0.0.1
net arp 10.0.0.2
exec PING.BIN -c 3 10.0.0.2
echo ping-online-launched
SCRIPT1
cat > "$RUN_DIR/script-2.txt" <<'SCRIPT2'
exec FETCH.BIN
SCRIPT2
cat > "$RUN_DIR/script-3.txt" <<'SCRIPT3'
echo online-ok
SCRIPT3

rm -f "$RUN_DIR/vm-serial.log" "$RUN_DIR/cap.bin" "$RUN_DIR/efi-vars.bin"
set +e
"$RUNNER" "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --net "$RUN_DIR/cap.bin" \
    --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 \
    --script "$RUN_DIR/script-1.txt" \
    --script2 "$RUN_DIR/script-2.txt" --script2-after 'ping statistics' \
    --script3 "$RUN_DIR/script-3.txt" --script3-after 'fetch: starting' \
    --script-expect $'FETCH.BIN exited status=42' --timeout 120 \
    > "$(art live-net-offline-c-run.txt)" 2>&1
RC_C=$?
set -e
cp "$RUN_DIR/vm-serial.log" "$(art live-net-offline-c-serial.log)"

SERIAL_C="$RUN_DIR/vm-serial.log"
C_PING_HDR=0; C_PING_LINE=0; C_PING_STATS=0; C_PING_LOSS=0; C_PING_EXIT=0
C_FETCH_CONN=0; C_FETCH_HTTP=0; C_FETCH_DONE=0; C_FETCH_EXIT=0; C_OK=0
C_NO_OFFLINE=0; C_NO_NOROUTE=0
if [ -f "$SERIAL_C" ]; then
    grep -a -qF -- 'PING 10.0.0.2 (10.0.0.2): 56 data bytes' "$SERIAL_C" && C_PING_HDR=1
    grep -a -qF -- '64 bytes from 10.0.0.2: icmp_seq=1' "$SERIAL_C" && C_PING_LINE=1
    grep -a -qF -- 'ping statistics' "$SERIAL_C" && C_PING_STATS=1
    grep -a -qF -- '0% packet loss' "$SERIAL_C" && C_PING_LOSS=1
    grep -a -qE -- 'PING\.BIN exited status=0|PING\.BIN.*exit=0x0000000000000000' "$SERIAL_C" && C_PING_EXIT=1
    grep -a -qF -- 'fetch: connected' "$SERIAL_C" && C_FETCH_CONN=1
    grep -a -qF -- 'HTTP/1.0 200 OK' "$SERIAL_C" && C_FETCH_HTTP=1
    grep -a -qF -- 'fetch: done' "$SERIAL_C" && C_FETCH_DONE=1
    grep -a -qE -- 'FETCH\.BIN exited status=42|FETCH\.BIN.*exit=0x000000000000002a' "$SERIAL_C" && C_FETCH_EXIT=1
    grep -a -qF -- 'echo online-ok' "$SERIAL_C" && C_OK=1
    # The preflight must not fire on a healthy network.
    grep -a -qF -- 'offline' "$SERIAL_C" || C_NO_OFFLINE=1
    grep -a -qF -- 'no route' "$SERIAL_C" || C_NO_NOROUTE=1
fi
check "C: ping header"                  "$C_PING_HDR"    1
check "C: ping reply line"              "$C_PING_LINE"   1
check "C: ping statistics footer"       "$C_PING_STATS"  1
check "C: ping 0% loss"                 "$C_PING_LOSS"   1
check "C: ping exit 0"                  "$C_PING_EXIT"   1
check "C: fetch connected"              "$C_FETCH_CONN"  1
check "C: fetch HTTP 200"               "$C_FETCH_HTTP"  1
check "C: fetch done"                   "$C_FETCH_DONE"  1
check "C: fetch exit 42"                "$C_FETCH_EXIT"  1
check "C: no offline false-positive"    "$C_NO_OFFLINE"  1
check "C: no no-route false-positive"   "$C_NO_NOROUTE"  1
check "C: shell responsive"             "$C_OK"          1
gate_end

# =============================================================================
# verdict
# =============================================================================
echo "--- runs: A rc=$RC_A (offline), B rc=$RC_B (no-route), C rc=$RC_C (online control) ---"
cat > "$REPORT" <<EOF
=== verify-live-net-offline report ===
revision:   $REVISION
branch:     $BRANCH
dirty:      $DIRTY
run_a_rc:   $RC_A
run_b_rc:   $RC_B
run_c_rc:   $RC_C
asserts:    $assert_count
failed:     $fail_count
EOF
cat "$REPORT"

if [ "$fail_count" -ne 0 ]; then
    echo "verify-live-net-offline: FAIL ($fail_count/$assert_count assertions failed)"
    exit 1
fi
echo "verify-live-net-offline: PASS ($assert_count/$assert_count)"
