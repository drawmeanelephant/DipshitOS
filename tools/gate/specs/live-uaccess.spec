# live-uaccess.spec -- fault-safe uaccess: EL0 observes EFAULT on a bad
# pointer and survives; the monitor command recovers a real data abort.
# Mirrors tools/verify-live-uaccess.sh (claim 6120).

vgate_name live-uaccess "EFAULT contract + data-abort recovery"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_note "script: syscalls / uaccess / echo rx-uaccess-ok"

vgate_file script.txt <<'EOF'
syscalls
uaccess
echo rx-uaccess-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect "rx-uaccess-ok"$'\n' --timeout 45

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'syscall: write ok n=23' 1
vgate_assert 01 serial-count 'uaccess: efault ok n=8' 1
vgate_assert 01 serial-exact '  0 sys_ping calls=2' 1
vgate_assert 01 serial-exact '  1 sys_write calls=3' 1
vgate_assert 01 serial-exact 'uaccess: valid=1 fault=1 recovered=1 copies=4 validation_faults=1' 1
vgate_assert 01 serial-exact 'rx-uaccess-ok' 1
vgate_assert 01 serial-exact 'userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0' 1
vgate_assert 01 serial-absent '[EXC] parking:'
