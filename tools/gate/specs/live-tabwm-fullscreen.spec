# live-tabwm-fullscreen.spec -- M42 SX5 (issue #986) class-B gate: Sexiburger tabbed desktop as PRIMARY manager

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
exec CALC.BIN
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

vgate_run A -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script-A.txt' --script2 '$RUN_DIR/script2-A.txt' --script2-after 'tabwm: sidebar-rendered' --script3 '$RUN_DIR/script3-A.txt' --script3-after 'calc: ready' --script-expect 'calc: resize relayout' --timeout 90

vgate_assert A serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert A serial-contains 'wm: autostart tabwm (settings wm=tabwm)'
vgate_assert A serial-contains 'tabwm: registered'
vgate_assert A serial-contains 'tabwm: sidebar-rendered'
vgate_assert A serial-contains 'calc: open id=2'
vgate_assert A serial-contains 'calc: tab-aware (full-viewport)'
vgate_assert A serial-contains 'calc: resize relayout'
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

vgate_run B -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script-B.txt' --script2 '$RUN_DIR/script2-B.txt' --script2-after 'tabwm: sidebar-rendered' --script3 '$RUN_DIR/script3-B.txt' --script3-after 'tabwm: launch' --script-expect 'calc: resize relayout' --timeout 120 --via-virtio --input-chords 'ctrl-space,6,4,-,b,i,t,return' --input-chords-after 'tabwm: sidebar-rendered'

vgate_assert B serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert B serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert B serial-contains 'tabwm: registered'
vgate_assert B serial-contains 'tabwm: sidebar-rendered'
vgate_assert B serial-contains 'tabwm: god-menu'
vgate_assert B serial-contains 'tabwm: launch CALC.BIN'
vgate_assert B serial-contains 'calc: open id=2'
vgate_assert B serial-contains 'calc: tab-aware (full-viewport)'
vgate_assert B serial-contains 'calc: resize relayout'
vgate_assert B serial-contains 'tabwm: tab-switch'
vgate_assert B serial-contains 'rx-m42-b'
vgate_assert B serial-absent '\[EXC\]'
vgate_assert B serial-absent '[EXC] parking:'
