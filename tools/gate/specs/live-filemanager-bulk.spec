# live-filemanager-bulk.spec -- M25 Lane A F1: multi-select + batch delete on VZ.
# Proves Ctrl+A selects all entries (n=4: DATA.TXT, FILE.BIN, HISTORY.TXT, README.TXT),
# 'd' opens delete confirmation, Return confirms; stepwise batch deletes all 4 files
# via sys_file_delete (slot 34 calls=4) and removes them from the host share disk.

vgate_name live-filemanager-bulk "M25 Lane A F1: multi-select + batch delete on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_setup_python <<'PY'
import os, shutil
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
shutil.copy("zig-out/bin/FILE.BIN", share)
with open(os.path.join(share, "README.TXT"), "w") as f:
    f.write("VirelaiOS general filesystem: host share fixtures\n")
with open(os.path.join(share, "DATA.TXT"), "w") as f:
    f.write("general data volume contents: 1234567890\n")
PY

vgate_file script.txt <<'EOF'
exec FILE.BIN
EOF

vgate_file settle.txt <<'EOF'
dui focus 0
vf ls
syscalls
echo m25-bulk-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio --script '$RUN_DIR/script.txt' --input-chords 'ctrl-a,d,return' --input-chords-after 'file: ready' --script2 '$RUN_DIR/settle.txt' --script2-after 'file: batch done n=4' --script2-delay 2 --script-expect 'm25-bulk-ok' --timeout 150

vgate_assert 01 serial-contains 'file: select all n=4'
vgate_assert 01 serial-contains 'file: del prompt n=4'
vgate_assert 01 serial-contains 'file: del 1/4 DATA.TXT'
vgate_assert 01 serial-contains 'file: del 2/4 FILE.BIN'
vgate_assert 01 serial-contains 'file: del 3/4 HISTORY.TXT'
vgate_assert 01 serial-contains 'file: del 4/4 README.TXT'
vgate_assert 01 serial-contains 'file: batch done n=4'
vgate_assert 01 serial-contains '34 sys_file_delete calls=4'
vgate_assert 01 serial-contains 'm25-bulk-ok'
vgate_assert 01 serial-absent '[EXC] parking'

vgate_assert 01 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for name in ["DATA.TXT", "README.TXT", "FILE.BIN"]:
    p = os.path.join(share, name)
    if os.path.exists(p):
        sys.exit(f"ERROR: {name} still exists in host share after batch delete")
print("bulk host-disk ok: deleted targets absent from host share")
PY
