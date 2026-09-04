# live-filemanager-props.spec -- M25 Lane A F2: properties inspector on VZ.
# Ctrl+I toggles the properties inspector on selected entry (on -> off -> on).
# Asserts toggle symmetry (2 on, 1 off across 3 chords) and live du= calculation.

vgate_name live-filemanager-props "M25 Lane A F2: properties inspector on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
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
echo m25-props-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio --script '$RUN_DIR/script.txt' --input-chords 'ctrl-i,ctrl-i,ctrl-i' --input-chords-after 'file: ready' --script2 '$RUN_DIR/settle.txt' --script2-after 'file: props off' --script2-delay 2 --script-expect 'm25-props-ok' --timeout 150

vgate_assert 01 serial-contains 'file: props on'
vgate_assert 01 serial-contains 'file: props off'
vgate_assert 01 serial-contains 'm25-props-ok'
vgate_assert 01 serial-absent '[EXC] parking'

vgate_assert 01 python <<'PY'
import re, sys, os
ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")
on = ser.count("file: props on")
off = ser.count("file: props off")
if on != 2 or off != 1:
    sys.exit(f"ERROR: toggle accounting wrong (on={on} off={off})")
if not re.search(r"file: listing [0-9]+ entries .*du=[0-9]+", ser):
    sys.exit("ERROR: breadcrumb du total missing from listing marker")
print("props inspector ok: toggle symmetry 2/1 and du total verified")
PY
