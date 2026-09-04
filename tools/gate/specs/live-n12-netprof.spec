# live-n12-netprof.spec -- NETPROF.BIN (exec'd) lists/loads network
# profiles, persists them to /host/NET.TXT, and exits 0.
# Mirrors tools/verify-live-n12-netprof.sh (M26 N12, issue #439).

vgate_name live-n12-netprof "NETPROF.BIN profiles live on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
exec NETPROF.BIN
EOF

vgate_file script-2.txt <<'EOF'
cat NET.TXT
procs
echo netprof-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'netprof: complete' --script-expect 'echo netprof-ok' --timeout 60

vgate_assert 01 serial-contains 'netprof: starting'
vgate_assert 01 serial-contains '--- network profiles ---'
vgate_assert 01 serial-contains 'profile default: ip=10.0.0.1 gw=10.0.0.2 dns=1.1.1.1'
vgate_assert 01 serial-contains 'profile home: ip=192.168.1.50 gw=192.168.1.1 dns=8.8.8.8'
vgate_assert 01 serial-contains 'netprof: saved to /host/NET.TXT'
vgate_assert 01 serial-contains 'netprof: complete'
vgate_assert 01 serial-contains 'default=10.0.0.1,10.0.0.2,1.1.1.1'
vgate_assert 01 serial-contains 'echo netprof-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -E: the exit-0 reap row (either the procs-table or the
# monitor exit row).
if not re.search(r"procs NETPROF\.BIN exited status=0|NETPROF.*state=exited.*0", ser):
    sys.exit("FAIL: no NETPROF.BIN exit-0 row")
print("netprof reap ok")
PY
