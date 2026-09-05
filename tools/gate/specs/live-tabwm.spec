# live-tabwm.spec -- M39 TWM3 (issue #930) class-B gate: the browser-style
#
# tabbed window manager server (TABWM.BIN) end to end on real VZ hardware.
#
# ONE headless boot with --screen only (GPU attached so the compositor is
# armed). The serial script drives the whole tabbed desktop lifecycle:
#
#   Phase 1 (--script, forwarded at boot):
#   1. `tabwm`          -> "tabwm: none (shim compositing)"   [shim mode, default]

vgate_name live-tabwm "M39 TWM3 (issue #930) class-B gate: the browser-style"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
tabwm
tabwm start
exec WINLOOP.BIN
EOF

vgate_file script2.txt <<'EOF'
tabwm
echo rx-tabwm-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after "winloop: loop ok" --script-expect "rx-tabwm-ok" --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: none (shim compositing)'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'tabwm: present'
vgate_assert 01 serial-contains 'tabwm: registered pid='
vgate_assert 01 serial-contains 'winloop: open id=2'
vgate_assert 01 serial-contains 'tabwm: tab-switch'
vgate_assert 01 serial-contains 'rx-tabwm-ok'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

