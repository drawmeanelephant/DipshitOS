# live-gfs.spec -- the general store IS the host share: `mount`
# reports it armed, the seeded README/DATA files list with the
# [host] window and cat correctly, hello.txt persists across the
# reboot into run B. The ANSI-tailed expects ride $'...'.
# Mirrors tools/verify-live-gfs.sh (M34 HF6, issue #740). DATAFILES
# is an OR (any of the three needles -- legacy overwrites the flag).

vgate_name live-gfs "general store on the host share, persistent across reboot on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_repeat 1 BOOTS

vgate_setup_python <<'PY'
import os
share = os.path.join(os.environ["RUN_DIR"], "share")
open(os.path.join(share, "README.TXT"), "w").write("VirelaiOS general store README")
open(os.path.join(share, "DATA.TXT"), "w").write("general data volume contents: 1234567890")
print("gfs fixtures ok")
PY

vgate_file script-A.txt <<'EOF'
mount
write hello.txt hello world
ls
cat README.TXT
cat DATA.TXT
EOF

vgate_file script-B.txt <<'EOF'
mount
ls
cat hello.txt
EOF

vgate_run A -- --script '$RUN_DIR/script-A.txt' --script-expect $'general data volume contents: 1234567890\n\x1b[32mvirelai> ' --timeout 40
vgate_run B -- --script '$RUN_DIR/script-B.txt' --script-expect $'hello world\n\x1b[32mvirelai> ' --timeout 40

vgate_assert A serial-contains 'mount: host share armed files=0x'
vgate_assert A serial-contains 'ls: host=0x'
vgate_assert A serial-contains 'write: ok (persisted'
vgate_assert A serial-contains 'general data volume contents'
vgate_assert A serial-contains 'hello world'
vgate_assert A python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Common requirement (both runs): the OR-needles + insensitive hello.
if not ("  README.TXT" in ser or "  DATA.TXT" in ser or "  [host]" in ser):
    sys.exit("FAIL: no data-files needle")
if "  hello" not in ser.lower():
    sys.exit("FAIL: hello.txt not listed")
print("gfs files ok")
PY
vgate_assert B serial-contains 'mount: host share armed files=0x'
vgate_assert B serial-contains 'ls: host=0x'
vgate_assert B serial-contains 'hello world'
vgate_assert B python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy DATAFILES is an OR across the three needles (flag
# overwrite); hello match is case-insensitive (-i).
if not ("  README.TXT" in ser or "  DATA.TXT" in ser or "  [host]" in ser):
    sys.exit("FAIL: no data-files needle")
if "  hello" not in ser.lower():
    sys.exit("FAIL: hello.txt not listed")
print("gfs files ok")
PY
