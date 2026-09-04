# live-filemanager-du.spec -- M25 F4: recursive disk usage (`du`) on VZ.
# Walks root directory recursively across subdirectories on host share and
# measures /EFI subtree with non-zero byte totals, matching du contract.

vgate_name live-filemanager-du "M25 F4: recursive disk usage on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
os.makedirs(os.path.join(share, "EFI"), exist_ok=True)
with open(os.path.join(share, "EFI", "BOOTAA64.EFI"), "wb") as f:
    f.write(bytes(range(100)))
PY

vgate_file script.txt <<'EOF'
du /
du /EFI
echo m25-du-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'm25-du-ok' --timeout 90

vgate_assert 01 serial-contains 'm25-du-ok'
vgate_assert 01 serial-contains 'du: /'
vgate_assert 01 serial-contains 'du: /EFI'
vgate_assert 01 serial-absent '[EXC] parking'

vgate_assert 01 python <<'PY'
import re, sys, os
ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")
if not re.search(r"du: / [1-9][0-9]* bytes \(dirs=[0-9]+\)", ser):
    sys.exit("ERROR: du / output missing or zero bytes")
if not re.search(r"du: /EFI [1-9][0-9]* bytes \(dirs=[0-9]+\)", ser):
    sys.exit("ERROR: du /EFI output missing or zero bytes")
print("du output ok")
PY
