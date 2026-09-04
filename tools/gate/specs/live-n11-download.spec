# live-n11-download.spec -- DOWNLOAD.BIN (exec'd) fetches the HTTP
# body over the host TCP responder and persists it to
# /host/DOWNLOAD.OUT -- the host-disk file is the ground truth (a
# serial-only proof would pass on an unpersisted claim).
# Mirrors tools/verify-live-n11-download.sh (M26 N11, issue #438).

vgate_name live-n11-download "DOWNLOAD.BIN HTTP fetch persisted to the host share on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec DOWNLOAD.BIN
echo download-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
echo download-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'download: complete' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'download: starting'
vgate_assert 01 serial-contains 'download: connected'
vgate_assert 01 serial-contains 'download: request sent'
vgate_assert 01 serial-contains 'download: file opened'
vgate_assert 01 serial-contains 'download: status 200'
vgate_assert 01 serial-contains 'download: saving to file'
vgate_assert 01 serial-contains 'download: complete'
vgate_assert 01 serial-contains 'echo download-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -E: the exit-0 reap row.
if not re.search(r"DOWNLOAD.BIN.*state=exited.*0|DOWNLOAD.BIN\s+exit=0x0000000000000000", ser):
    sys.exit("FAIL: no DOWNLOAD.BIN exit-0 row")
# Legacy HF5-DISK: the exact HTTP body on the host share.
p = os.path.join(os.environ["VG_SHARE"], "DOWNLOAD.OUT")
try:
    body = open(p, "rb").read()
except OSError:
    sys.exit("FAIL: DOWNLOAD.OUT missing from the host share")
if b"Hello from VirelaiOS Host!" not in body:
    sys.exit("FAIL: DOWNLOAD.OUT content mismatch on the host share")
print("download reap + host-disk body ok")
PY
