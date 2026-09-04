# live-user-fs.spec -- claim 0510 (Milestone 10 F4): userland storage ABI & utilities on VZ.
# Proves round-trip persistence across two boots sharing the host share:
# Boot A: SAVETEXT.BIN writes /host/hello.txt via sys_file_open/write/close.
# Boot B: TYPE.BIN reads persistent payload via sys_file_read, DIR.BIN enumerates
# /host via sys_dir_list, and host disk verifies hello.txt payload.

vgate_name live-user-fs "Milestone 10 F4: userland storage ABI & utilities on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 PAIRS

vgate_setup_python <<'PY'
import os, shutil
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
shutil.copy("zig-out/bin/SAVETEXT.BIN", share)
shutil.copy("zig-out/bin/TYPE.BIN", share)
shutil.copy("zig-out/bin/DIR.BIN", share)
PY

vgate_file script-A.txt <<'EOF'
exec SAVETEXT.BIN
echo done-savetext
procs
EOF

vgate_file script-B.txt <<'EOF'
exec TYPE.BIN
exec DIR.BIN
echo done-fs-read
procs
EOF

vgate_run A -- --script '$RUN_DIR/script-A.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'procs SAVETEXT.BIN exited status=0' --timeout 40
vgate_run B -- --script '$RUN_DIR/script-B.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'procs DIR.BIN exited status=0' --timeout 40

vgate_assert A serial-contains 'savetext: wrote /host/hello.txt'
vgate_assert A serial-contains 'procs SAVETEXT.BIN exited status=0'
vgate_assert A serial-absent '[EXC] parking'

vgate_assert B serial-contains 'Hello from VirelaiOS EL0 Storage!'
vgate_assert B serial-contains 'procs TYPE.BIN exited status=0'
vgate_assert B serial-contains 'dir: listing /host'
vgate_assert B serial-contains 'dir: success'
vgate_assert B serial-contains 'procs DIR.BIN exited status=0'
vgate_assert B serial-absent '[EXC] parking'

vgate_assert B python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace").lower()
if "hello.txt" not in ser:
    sys.exit("ERROR: hello.txt missing from DIR.BIN enumeration")
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
hpath = os.path.join(share, "hello.txt")
if not os.path.exists(hpath):
    sys.exit("ERROR: hello.txt missing from host share")
data = open(hpath, "r", errors="replace").read()
if "Hello from VirelaiOS EL0 Storage!" not in data:
    sys.exit("ERROR: hello.txt content mismatch on host share")
print("user-fs ok: hello.txt enumerated in guest and verified on host disk")
PY
