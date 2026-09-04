# live-strace.spec -- M22 D5: per-syscall tracing.
# Traces syscalls for exec'd HELLO.ELF, prints named lines with args and results,
# and verifies clean disarm with 'strace off'.

vgate_name live-strace "M22 D5: per-syscall tracing"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
strace exec HELLO.ELF
echo strace-mid
EOF

vgate_file script2.txt <<'EOF'
crash
sym
strace off
echo rx-strace-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'tasks user-exec exited status=42' --script-expect 'rx-strace-ok' --timeout 90

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-exact 'strace: armed' 1
vgate_assert 01 serial-count '] sys_write(' 1
vgate_assert 01 serial-count '] sys_exit(' 1
vgate_assert 01 serial-exact 'elf: hello from HELLO.ELF' 1
vgate_assert 01 serial-exact 'tasks user-exec exited status=42' 1
vgate_assert 01 serial-exact 'strace: off' 1
vgate_assert 01 serial-exact 'rx-strace-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
