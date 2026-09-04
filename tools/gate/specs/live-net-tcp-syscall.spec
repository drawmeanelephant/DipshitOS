# live-net-tcp-syscall.spec -- TCP.BIN (exec'd) drives the TCP
# syscall seam from EL0: connect, echo round trip, exit 18; the
# observation phase re-reads slots 30-33 with real call counts.
# Mirrors tools/verify-live-net-tcp-syscall.sh (claim 7483, card N1).

vgate_name live-net-tcp-syscall "TCP.BIN drives slots 30-33 from EL0 on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec TCP.BIN
echo tcp-syscall-ready
EOF

vgate_file script-2.txt <<'EOF'
syscalls
tasks
net
echo net-tcp-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:9999 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'tcp: got echo hello' --script-expect 'tasks user-exec reaped' --timeout 90

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'tcp: connected'
vgate_assert 01 serial-contains 'tcp: got echo hello'
vgate_assert 01 serial-contains 'procs TCP.BIN exited status=18'
vgate_assert 01 serial-contains 'tasks user-exec exited status=18'
vgate_assert 01 serial-contains 'tasks user-exec reaped'
vgate_assert 01 serial-contains 'echo net-tcp-ok'
vgate_assert 01 output-contains "NET-TCP: answered the guest's SYN"
vgate_assert 01 output-contains "NET-TCP: echoed the guest's 5-byte data"
vgate_assert 01 output-contains "NET-TCP: answered the guest's FIN"
vgate_assert 01 output-contains 'net-tcp-respond: ENABLED'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Legacy -E: the syscall report shape (counts drift -- rows below).
if not re.search(r"syscalls: slots=[0-9]+ implemented=[0-9]+", ser):
    sys.exit("FAIL: no syscalls report")
# Markers IN ORDER: connected, echo, procs-exit.
pos = []
for m in ("tcp: connected", "tcp: got echo hello", "procs TCP.BIN exited status=18"):
    idx = next((i for i, l in enumerate(lines) if m in l), None)
    if idx is None:
        sys.exit("FAIL: marker absent: %s" % m)
    pos.append(idx)
if any(b <= a for a, b in zip(pos, pos[1:])):
    sys.exit("FAIL: markers out of order: %s" % list(zip(pos)))
# Seam rows 30-33 show real call counts (present, never "=0").
for row in ("  30 sys_tcp_connect calls=", "  31 sys_tcp_send calls=",
            "  32 sys_tcp_recv calls=", "  33 sys_tcp_close calls="):
    if row not in ser or (row + "0") in ser:
        sys.exit("FAIL: seam row missing or zero: %r" % row)
print("tcp-syscall order + rows ok")
PY
