#!/usr/bin/env bash
#
# verify-live-net-tcp-syscall.sh -- claim 7483 (milestone twelve, card N1, Issue #148)
# class-B gate: the TCP syscall seam (sys_tcp_connect, sys_tcp_send, sys_tcp_recv,
# sys_tcp_close) observed end to end on real VZ hardware — an EL0 USER PROGRAM
# (TCP.BIN, loaded by `exec`) connects to 10.0.0.2:9999, sends "hello", receives echo,
# closes the connection, and exits with status 18.
#
# Mechanism:
#   1. `net ip 10.0.0.1` + `net arp 10.0.0.2` primes the network stack and ARP table.
#   2. `exec TCP.BIN` loads the EL0 proof binary:
#      - `sys_tcp_connect(10.0.0.2, 9999)` (slot 30) -> connects, prints "tcp: connected"
#      - `sys_tcp_send("hello", 5)` (slot 31) -> sends 5 bytes
#      - `sys_tcp_recv(buf, 64)` (slot 32) -> receives echo, prints "tcp: got echo hello"
#      - `sys_tcp_close()` (slot 33) -> closes connection
#      - `sys_exit(18)` (slot 3) -> exits 18
#   3. Script2 runs observation commands (`syscalls`, `net`).
#
# Class B — Apple silicon + VZ only; boots real VMs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-net-tcp-syscall-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-net-tcp-syscall-report.txt"

echo "=== verify-live-net-tcp-syscall: claim 7483 — the TCP syscall seam live on VZ (TCP.BIN from EL0: connect, send, recv echo, close, exit 18) ==="

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
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- scripted keystrokes -----------------------------------------------------
cat > artifacts/live-net-tcp-syscall-script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec TCP.BIN
echo tcp-syscall-ready
EOF
cat > artifacts/live-net-tcp-syscall-script-2.txt <<'EOF'
syscalls
tasks
net
echo net-tcp-ok
EOF

# --- the run ----------------------------------------------------------------
rm -f artifacts/efi-vars.bin artifacts/vm-serial.log artifacts/live-net-tcp-syscall-cap.bin
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --net artifacts/live-net-tcp-syscall-cap.bin \
    --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:9999 \
    --script artifacts/live-net-tcp-syscall-script-1.txt \
    --script2 artifacts/live-net-tcp-syscall-script-2.txt --script2-after 'tcp: got echo hello' \
    --script-expect $'tasks user-exec reaped' --timeout 90 \
    > artifacts/live-net-tcp-syscall-run.txt 2>&1
RC=$?
set -e
[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-net-tcp-syscall-serial.log || true

# --- assertions -------------------------------------------------------------
SERIAL="artifacts/vm-serial.log"
SERIAL_BYTES=0; IPSET=0
CONNECTED=0; GOTECHO=0; ORDER=0
EXITP=0; EXITT=0; REAPED=0
SYSCOUNT=0; TCPROWS=0; OK=0

if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    grep -a -qF -- "net ip: ip=10.0.0.1" "$SERIAL" && IPSET=1

    l_conn=$(grep -a -nF -- "tcp: connected" "$SERIAL" | head -1 | cut -d: -f1 || true)
    l_echo=$(grep -a -nF -- "tcp: got echo hello" "$SERIAL" | head -1 | cut -d: -f1 || true)
    l_exit=$(grep -a -nF -- "procs TCP.BIN exited status=18" "$SERIAL" | head -1 | cut -d: -f1 || true)

    [ -n "$l_conn" ] && [ -n "$l_echo" ] && [ -n "$l_exit" ] && \
        [ "$l_conn" -lt "$l_echo" ] && [ "$l_echo" -lt "$l_exit" ] && ORDER=1
    [ -n "$l_conn" ] && CONNECTED=1
    [ -n "$l_echo" ] && GOTECHO=1
    [ -n "$l_exit" ] && EXITP=1

    grep -a -qF -- "tasks user-exec exited status=18" "$SERIAL" && EXITT=1
    grep -a -qF -- "tasks user-exec reaped" "$SERIAL" && REAPED=1

    grep -a -qF -- "syscalls: slots=64 implemented=34" "$SERIAL" && SYSCOUNT=1
    for row in "  30 sys_tcp_connect calls=" "  31 sys_tcp_send calls=" "  32 sys_tcp_recv calls=" "  33 sys_tcp_close calls="; do
        if grep -a -qF -- "$row" "$SERIAL" && ! grep -a -qF -- "${row}0" "$SERIAL"; then
            TCPROWS=$((TCPROWS + 1))
        fi
    done
    grep -a -qF -- "echo net-tcp-ok" "$SERIAL" && OK=1
fi

ANETSYN=0; ANETDATA=0; ANETFIN=0; ARUNNER=0
if [ -f artifacts/live-net-tcp-syscall-run.txt ]; then
    grep -a -qF -- "NET-TCP: answered the guest's SYN" artifacts/live-net-tcp-syscall-run.txt && ANETSYN=1
    grep -a -qF -- "NET-TCP: echoed the guest's 5-byte data" artifacts/live-net-tcp-syscall-run.txt && ANETDATA=1
    grep -a -qF -- "NET-TCP: answered the guest's FIN" artifacts/live-net-tcp-syscall-run.txt && ANETFIN=1
    grep -a -qF -- "net-tcp-respond: ENABLED" artifacts/live-net-tcp-syscall-run.txt && ARUNNER=1
fi

cat > "$REPORT" <<EOF
=== verify-live-net-tcp-syscall report ===
revision:        $REVISION
branch:          $BRANCH
dirty-files:     $DIRTY
runner_rc:       $RC
serial_bytes:    $SERIAL_BYTES
net_ip_set:      $IPSET
tcp_connected:   $CONNECTED
tcp_got_echo:    $GOTECHO
tcp_order:       $ORDER
procs_exit_18:   $EXITP
tasks_exit_18:   $EXITT
tasks_reaped:    $REAPED
syscalls_count:  $SYSCOUNT
tcp_rows_active: $TCPROWS / 4
responder_syn:   $ANETSYN
responder_data:  $ANETDATA
responder_fin:   $ANETFIN
runner_enabled:  $ARUNNER
EOF

cat "$REPORT"

# Final gate evaluation
if [ "$RC" -eq 0 ] && [ "$CONNECTED" -eq 1 ] && [ "$GOTECHO" -eq 1 ] && [ "$ORDER" -eq 1 ] && \
   [ "$EXITP" -eq 1 ] && [ "$EXITT" -eq 1 ] && [ "$REAPED" -eq 1 ] && [ "$SYSCOUNT" -eq 1 ] && \
   [ "$TCPROWS" -eq 4 ] && [ "$ANETSYN" -eq 1 ] && [ "$ANETDATA" -eq 1 ] && [ "$ANETFIN" -eq 1 ]; then
    echo "=== verify-live-net-tcp-syscall: PASS ==="
    exit 0
else
    echo "=== verify-live-net-tcp-syscall: FAIL ==="
    exit 1
fi
