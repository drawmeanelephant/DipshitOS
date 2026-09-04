# live-inventory.spec -- M22 D16: which + inventory on VZ.
# Resolves all three command classes (builtin, monitor, app) + not-found,
# and inventory lists APPS.TXT applications.

vgate_name live-inventory "M22 D16: which + inventory on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
which type
which stat
which NOTEPAD.BIN
which nope.bin
inventory
echo rx-inv-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'rx-inv-ok' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'type: shell builtin'
vgate_assert 01 serial-contains 'stat: monitor command'
vgate_assert 01 serial-contains 'NOTEPAD.BIN: host-share application'
vgate_assert 01 serial-contains 'nope.bin: not found'
vgate_assert 01 serial-contains 'rx-inv-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ['VG_SER']).read()
if not re.search(r'inventory: \d+ application\(s\):', ser):
    sys.exit("missing inventory header in serial log")
if "NOTEPAD.BIN" not in ser:
    sys.exit("NOTEPAD.BIN not listed in inventory")
PY
