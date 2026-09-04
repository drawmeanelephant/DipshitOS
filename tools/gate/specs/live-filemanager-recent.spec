# live-filemanager-recent.spec -- M25 Lane B F5: recent ring on VZ.
# Proves opening a file persists the recent-files ring to /host/RECENT.SAV,
# Escape re-lists and injects the virtual RECENT entry, Return opens the
# RECENT pseudo-listing, and Return opens the stored full path directly.

vgate_name live-filemanager-recent "M25 Lane B F5: recent ring on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_setup_python <<'PY'
import os, shutil
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
shutil.copy("zig-out/bin/FILE.BIN", share)
with open(os.path.join(share, "DATA.TXT"), "w") as f:
    f.write("general data volume contents: 1234567890\n")
PY

vgate_file script.txt <<'EOF'
exec FILE.BIN
EOF

vgate_file settle.txt <<'EOF'
dui focus 0
syscalls
echo m25-recent-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio --script '$RUN_DIR/script.txt' --input-chords 'return,escape,return,return' --input-chords-after 'file: ready' --script2 '$RUN_DIR/settle.txt' --script2-after 'file: open /host/DATA.TXT' --script2-delay 2 --script-expect 'm25-recent-ok' --timeout 150

vgate_assert 01 serial-contains 'file: recent saved n=1'
vgate_assert 01 serial-contains 'recent=virtual'
vgate_assert 01 serial-contains 'file: recent open n=1'
vgate_assert 01 serial-contains 'file: open /host/DATA.TXT'
vgate_assert 01 serial-contains 'm25-recent-ok'
vgate_assert 01 serial-absent '[EXC] parking'

vgate_assert 01 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
recent_path = os.path.join(share, "RECENT.SAV")
if not os.path.exists(recent_path):
    sys.exit("ERROR: RECENT.SAV missing from host share")
data = open(recent_path, "r", errors="replace").read()
if "/host/DATA.TXT" not in data:
    sys.exit("ERROR: RECENT.SAV does not contain /host/DATA.TXT")
print("recent ring ok: /host/DATA.TXT persisted in RECENT.SAV on host share")
PY
