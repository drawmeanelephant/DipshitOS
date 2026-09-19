# live-inventory.spec -- M22 D16: which + inventory on VZ.
# Resolves all three command classes (builtin, monitor, app) + not-found,
# and inventory lists APPS.TXT applications.
#
# M66c (#1445): the dock's editor entry is NOTE.ELF now, so `image/apps.txt`
# (which gate-run copies in as the share's APPS.TXT) names it and the app query
# follows. NOTE.ELF is a staged Go ELF, not a seeded .BIN, hence the setup that
# copies it into the share.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name live-inventory "M22 D16: which + inventory on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
which type
which stat
which NOTE.ELF
which nope.bin
inventory
echo rx-inv-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "NOTE.ELF")
if not os.path.exists(src):
    sys.exit("NOTE.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-note.sh")
shutil.copy(src, os.path.join(share, "NOTE.ELF"))
print("staged NOTE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "NOTE.ELF")))
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'rx-inv-ok' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'type: shell builtin'
vgate_assert 01 serial-contains 'stat: monitor command'
vgate_assert 01 serial-contains 'NOTE.ELF: host-share application'
vgate_assert 01 serial-contains 'nope.bin: not found'
vgate_assert 01 serial-contains 'rx-inv-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ['VG_SER']).read()
if not re.search(r'inventory: \d+ application\(s\):', ser):
    sys.exit("missing inventory header in serial log")
if "NOTE.ELF" not in ser:
    sys.exit("NOTE.ELF not listed in inventory")
PY
