# live-fs.spec -- host-share storage (M34 HF6): run A writes
# hello.txt, lists it [host], cats it, lists the seeded subdir, and
# hits the honest 2 KiB direct-read cap; run B fresh-boots the SAME
# share and still lists + prints the file; the host-disk bytes are
# the ground truth. The ANSI-tailed script-expects ride $'...'
# (the merged wave-1a n8 pattern).
# Mirrors tools/verify-live-fs.sh (issue #740). Two harness notes:
# per-TAG efi-vars rm (legacy reuses A's store in B -- neutral for
# file paths) and no inter-run sleep (local APFS needs none).

vgate_name live-fs "write/ls/cat persist through reboot on the host share on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_repeat 1 PAIRS

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
os.makedirs(os.path.join(share, "sub"), exist_ok=True)
os.makedirs(os.path.join(share, "sub", "deeper"), exist_ok=True)
open(os.path.join(share, "sub", "hello.txt"), "w").write("hello from the seeded share")
open(os.path.join(share, "sub", "big.txt"), "wb").write(bytes((i * 7 + 3) & 0xff for i in range(4000)))
open(os.path.join(share, "sub", "deeper", "nested.txt"), "w").write("nested level 2\n")
print("fs fixtures ok")
PY

vgate_file script-A.txt <<'EOF'
write hello.txt hello world
ls
cat hello.txt
ls sub
cat sub/big.txt
version
EOF

vgate_file script-B.txt <<'EOF'
ls
cat hello.txt
version
EOF

vgate_run A -- --script '$RUN_DIR/script-A.txt' --script-expect $'direct read caps at 0x0000000000000800 bytes\n\x1b[31mvirelai> ' --timeout 40
vgate_run B -- --script '$RUN_DIR/script-B.txt' --script-expect $'hello world\n\x1b[32mvirelai> ' --timeout 40

vgate_assert A serial-contains 'write: ok (persisted'
vgate_assert A serial-contains 'ls: host=0x'
vgate_assert A serial-contains '  hello.txt'
vgate_assert A serial-contains 'ls: sub entries=0x'
vgate_assert A serial-contains 'direct read caps at 0x0000000000000800'
vgate_assert A serial-contains 'hello world'
vgate_assert A serial-contains 'vf: probe 32k ok'
vgate_assert B serial-contains 'ls: host=0x'
vgate_assert B serial-contains '  hello.txt'
vgate_assert B serial-contains 'hello world'
vgate_assert B serial-contains 'vf: probe 32k ok'
vgate_assert B python <<'PY'
import os, sys
# HF6-DISK: hello.txt on the host share still carries the exact bytes
# (legacy compares $(cat) ==, which strips trailing newlines).
p = os.path.join(os.environ["VG_SHARE"], "hello.txt")
try:
    data = open(p, "rb").read()
except OSError:
    sys.exit("FAIL: hello.txt missing from the host share")
if data.rstrip(b"\n") != b"hello world":
    sys.exit("FAIL: hello.txt content off: %r" % data[:40])
print("fs host-disk ok")
PY
