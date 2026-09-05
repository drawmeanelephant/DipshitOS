# live-clipboard.spec -- milestone-fourteen card S1 class-B gate (claim
#
# 0169): the bounded shared kernel clipboard on real VZ. Host scripted
# keystrokes drive the terminal half (`clip <text...>` sets it, `clip` pastes
# it) and assert the same buffer round-trips across multiple sets/gets, then
# `syscalls` proves the ADR 0007 slots 38/39 are wired into the live dispatch
# table (implemented=46).
#
# Mechanism: the production image is booted with the runner's scripted-input

vgate_name live-clipboard "milestone-fourteen card S1 class-B gate (claim"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
clip hello world
clip
clip second
clip
syscalls
echo clip-live-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect "clip-live-ok" --timeout 40

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'clip: stored 11 bytes'
vgate_assert 01 serial-contains 'clip: hello world'
vgate_assert 01 serial-contains 'clip: stored 6 bytes'
vgate_assert 01 serial-contains 'clip: second'
vgate_assert 01 serial-contains 'syscalls: slots='
vgate_assert 01 serial-contains 'implemented='
vgate_assert 01 serial-contains '  38 sys_clipboard_set calls='
vgate_assert 01 serial-contains '  39 sys_clipboard_get calls='
vgate_assert 01 serial-contains 'clip-live-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
