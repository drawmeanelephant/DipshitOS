# go-wm-hid.spec -- M63a (issue #1419) class-B gate: GOTABWM drains the
# kernel's WM pointer/key fan-out (kinds 19/21).
#
# Seed wm=none, exec GOTABWM.ELF (explicit seat, not the boot-default path).
# SPIKE + --via-virtio so --pointer-virtio can inject. One click after a
# marker the PROGRAM printed (`gotabwm: rail`). Serial `gotabwm: ptr` is the
# proof the seat logged a real kind-19 event, not an empty poll. No hit-test,
# no chords, no reorder — this spec is the HID skeleton later M63 cards grow.
# Do not overload go-wm-seat / go-wm-tabs.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gotabwm-hid-ok`, which only
# the script prints, and every stage gate waits on guest output the program
# produces (`gotabwm: win focus`, `gotabwm: rail`,
# `wm: unregistered, shim resumed`).

vgate_name go-wm-hid "issue #1419 M63a: GOTABWM drains WM pointer (kind 19) on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
EOF

vgate_file script3.txt <<'EOF'
wm
dui
echo rx-gotabwm-hid-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
print("staged GOTABWM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTABWM.ELF")))
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (wm=none: shim-only boot, explicit seat opt-in)")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '640,360,c' \
    --pointer-virtio-after 'gotabwm: rail' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: rail'
vgate_assert 01 serial-contains 'gotabwm: ptr'
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
