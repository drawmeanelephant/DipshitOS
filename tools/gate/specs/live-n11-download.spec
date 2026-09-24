# live-n11-download.spec -- GOFETCH.ELF --download (exec'd) fetches the
# cleartext HTTP body over the host TCP responder and persists it to
# /host/DOWNLOAD.OUT -- the host-disk file is the ground truth (a
# serial-only proof would pass on an unpersisted claim).
# M78b (#1683): the Zig DOWNLOAD.BIN this gate used to exec is retired. The
# download rows moved onto GOFETCH.ELF's --download mode (user/go/fetch
# legacy.go): same `download:` markers, same default destination, same
# exit 0. The Go save is crash-safe (temp + fsync + publish), so a failed
# save can never leave a partial DOWNLOAD.OUT behind.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-web.sh fetch GOFETCH -> .build/go/GOFETCH.ELF

vgate_name live-n11-download "GOFETCH.ELF --download HTTP fetch persisted to the host share on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOFETCH.ELF")
if not os.path.exists(src):
    sys.exit("GOFETCH.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-web.sh fetch GOFETCH")
shutil.copy(src, os.path.join(share, "GOFETCH.ELF"))
print("staged GOFETCH.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOFETCH.ELF")))
PY

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOFETCH.ELF --download
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
# The exit-0 reap row now names GOFETCH.ELF.
if not re.search(r"GOFETCH\.ELF.*state=exited.*0|GOFETCH\.ELF\s+exit=0x0000000000000000", ser):
    sys.exit("FAIL: no GOFETCH.ELF exit-0 row")
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
