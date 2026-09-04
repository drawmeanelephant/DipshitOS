# live-elf.spec -- M22 D1: load and execute ELF32 from the ESP at EL0.
# HELLO.ELF parsed by kernel/src/elf.zig through the exec magic-sniff path,
# mapped at the EL0 text aperture, executed (sys_write marker), and exited cleanly.

vgate_name live-elf "M22 D1: load and execute ELF32 at EL0"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
ls
exec HELLO.ELF
echo rx-elf-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'HELLO.ELF' 2
vgate_assert 01 serial-contains 'exec: loaded HELLO.ELF size='
vgate_assert 01 serial-exact 'elf: hello from HELLO.ELF' 1
vgate_assert 01 serial-exact 'tasks user-exec exited status=42' 1
vgate_assert 01 serial-exact 'tasks user-exec reaped' 1
vgate_assert 01 serial-exact 'rx-elf-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
