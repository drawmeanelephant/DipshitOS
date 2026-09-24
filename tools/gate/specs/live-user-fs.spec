# live-user-fs.spec — userland storage ABI & utilities on VZ.
# Proves round-trip persistence across two boots sharing the host share:
# Boot A: headless GOSH redirection writes /host/hello.txt through the file ABI.
# Boot B: headless GOSH cat reads the payload back and GOFILES lists /host.

vgate_name live-user-fs "userland storage ABI & utilities on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 PAIRS

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, script in (("GOSH.ELF", "build-gosh.sh"),
                      ("GOFILES.ELF", "build-files.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash tools/go/%s"
                 % (name, src, script))
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)"
          % (name, os.path.getsize(os.path.join(share, name))))
PY

vgate_file script-A.txt <<'EOF'
set GOMAXPROCS=1
exec GOSH.ELF -c "echo Hello from VirelaiOS EL0 Storage! > /host/hello.txt"
EOF

vgate_file script-A2.txt <<'EOF'
procs
echo done-user-fs-write
EOF

vgate_file script-B.txt <<'EOF'
set GOMAXPROCS=1
exec GOSH.ELF -c "cat /host/hello.txt"
EOF

vgate_file script-B2.txt <<'EOF'
exec GOFILES.ELF /host
EOF

vgate_file script-B3.txt <<'EOF'
procs
echo done-user-fs-read
EOF

vgate_run A -- --script '$RUN_DIR/script-A.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script-A2.txt' --script2-after 'tasks user-exec exited status=0' --script-expect 'done-user-fs-write' --timeout 60
vgate_run B -- --display --screen '$RUN_DIR/screen' --via-virtio --script '$RUN_DIR/script-B.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script-B2.txt' --script2-after 'tasks user-exec exited status=0' --input-chords 'q' --input-chords-after 'gofiles: ready' --script3 '$RUN_DIR/script-B3.txt' --script3-after 'gofiles OK' --script-expect 'done-user-fs-read' --timeout 120

vgate_assert A serial-contains 'exec: loaded GOSH.ELF'
vgate_assert A serial-contains 'tasks user-exec exited status=0'
vgate_assert A serial-contains 'procs GOSH.ELF exited status=0'
vgate_assert A serial-contains 'done-user-fs-write'
vgate_assert A serial-absent '[EXC] parking'

vgate_assert B serial-contains 'Hello from VirelaiOS EL0 Storage!'
vgate_assert B serial-contains 'procs GOSH.ELF exited status=0'
vgate_assert B serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert B serial-contains 'gofiles: list /host'
vgate_assert B serial-contains 'gofiles: entry hello.txt file'
vgate_assert B serial-contains 'gofiles: ready'
vgate_assert B serial-contains 'gofiles: close'
vgate_assert B serial-contains 'gofiles OK'
vgate_assert B serial-contains 'procs GOFILES.ELF exited status=0'
vgate_assert B serial-contains 'done-user-fs-read'
vgate_assert B serial-absent '[EXC] parking'

vgate_assert B python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace").lower()
if "hello.txt" not in ser:
    sys.exit("ERROR: hello.txt missing from GOFILES enumeration")
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
hpath = os.path.join(share, "hello.txt")
if not os.path.exists(hpath):
    sys.exit("ERROR: hello.txt missing from host share")
data = open(hpath, "r", errors="replace").read()
if "Hello from VirelaiOS EL0 Storage!" not in data:
    sys.exit("ERROR: hello.txt content mismatch on host share")
print("user-fs ok: GOSH round-trip and GOFILES enumeration verified")
PY
