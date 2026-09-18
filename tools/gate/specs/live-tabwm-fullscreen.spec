# live-tabwm-fullscreen.spec -- M42 SX5 (issue #986) class-B gate: Sexiburger tabbed desktop as PRIMARY manager
#
# M62h: Zig CALC.BIN is gone. Boot A execs leftover NOTEPAD.BIN. Boot B's
# god-menu types "64-bit" and launches GOCALC.ELF from APPS.TXT.

vgate_name live-tabwm-fullscreen "M42 SX5: Sexiburger tabbed desktop as PRIMARY manager"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file share/SETTINGS.TXT <<'EOF'
#v1
wm=tabwm
EOF

vgate_file script-A.txt <<'EOF'
echo boot-a-idle
EOF

vgate_file script2-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file script3-A.txt <<'EOF'
dui
echo rx-m42-ok
EOF

vgate_file script-B.txt <<'EOF'
tabwm start
echo boot-b-idle
EOF

vgate_file script2-B.txt <<'EOF'
echo rx-m42-b-ok
EOF

vgate_file script3-B.txt <<'EOF'
procs
echo rx-m42-b2-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
PY

# Flake #1063: script3 runs AFTER the functional completion marker
# (`notepad: resize relayout`), so its `dui`/`echo` round trip is the LAST
# thing before --script-expect.
vgate_run A -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script-A.txt' --script2 '$RUN_DIR/script2-A.txt' --script2-after 'tabwm: sidebar-rendered' --script3 '$RUN_DIR/script3-A.txt' --script3-after 'notepad: resize relayout' --script-expect 'rx-m42-ok' --timeout 90

vgate_assert A serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert A serial-contains 'wm: autostart tabwm (settings wm=tabwm)'
vgate_assert A serial-contains 'tabwm: registered'
vgate_assert A serial-contains 'tabwm: sidebar-rendered'
vgate_assert A serial-contains 'notepad: open id=2'
vgate_assert A serial-contains 'notepad: tab-aware (full-viewport)'
vgate_assert A serial-contains 'notepad: resize relayout'
vgate_assert A serial-contains 'tabwm: tab-switch'
vgate_assert A serial-contains 'rx-m42-ok'
vgate_assert A serial-absent '\[EXC\]'
vgate_assert A serial-absent '[EXC] parking:'
vgate_assert A python <<'PY'
import os
settings = os.path.join(os.environ.get("VG_SHARE", ""), "SETTINGS.TXT")
if os.path.exists(settings):
    os.remove(settings)
PY

# God-menu types "64-bit" (APPS.TXT display name) and launches GOCALC.ELF.
vgate_run B -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script-B.txt' --script2 '$RUN_DIR/script2-B.txt' --script2-after 'tabwm: sidebar-rendered' --script3 '$RUN_DIR/script3-B.txt' --script3-after 'gocalc: present' --script-expect 'rx-m42-b2-ok' --timeout 180 --via-virtio --input-chords 'ctrl-space,6,4,-,b,i,t,return' --input-chords-after 'tabwm: sidebar-rendered'

vgate_assert B serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert B serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert B serial-contains 'tabwm: registered'
vgate_assert B serial-contains 'tabwm: sidebar-rendered'
vgate_assert B serial-contains 'tabwm: god-menu'
vgate_assert B serial-contains 'tabwm: launch GOCALC.ELF'
vgate_assert B serial-contains 'gocalc: open id='
vgate_assert B serial-contains 'gocalc: declare accepted'
vgate_assert B serial-contains 'gocalc: present'
vgate_assert B serial-contains 'tabwm: tab-switch'
vgate_assert B serial-contains 'rx-m42-b'
vgate_assert B serial-absent '\[EXC\]'
vgate_assert B serial-absent '[EXC] parking:'
