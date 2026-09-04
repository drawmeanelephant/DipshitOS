# live-fetch.spec -- FETCH.BIN (exec'd) performs the HTTP/1.0 fetch
# over the host TCP responder: headers before body, 200 OK, the host
# body on the wire, exit 42.
# Mirrors tools/verify-live-fetch.sh (claim 5416, card N3).

vgate_name live-fetch "FETCH.BIN HTTP fetch from EL0 on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec FETCH.BIN
echo fetch-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
echo fetch-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'fetch: done' --script-expect 'tasks user-exec reaped' --timeout 90

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'fetch: starting'
vgate_assert 01 serial-contains 'fetch: connected'
vgate_assert 01 serial-contains 'fetch: request sent'
vgate_assert 01 serial-contains 'HTTP/1.0 200 OK'
vgate_assert 01 serial-contains 'Hello from VirelaiOS Host!'
vgate_assert 01 serial-contains 'fetch: done'
vgate_assert 01 serial-contains 'fetch: headers'
vgate_assert 01 serial-contains '--- response headers ---'
vgate_assert 01 serial-contains '--- response body ---'
vgate_assert 01 serial-contains 'echo fetch-ok'
vgate_assert 01 output-contains "NET-TCP: answered the guest's SYN"
vgate_assert 01 output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert 01 output-contains 'net-tcp-respond: ENABLED'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -E: the exit-42 row (monitor hex, procs-table, or exit hex).
if not re.search(r"FETCH.BIN\s+exit=0x000000000000002a|FETCH.BIN.*state=exited.*42|FETCH.BIN.*exit=0x000000000000002a", ser):
    sys.exit("FAIL: no FETCH.BIN exit-42 row")
# Legacy byte-offset order: the body section follows the headers.
hi = ser.find("--- response headers ---")
bi = ser.find("--- response body ---")
if hi < 0 or bi < 0 or not (bi > hi):
    sys.exit("FAIL: body section not after headers")
print("fetch exit + order ok")
PY
