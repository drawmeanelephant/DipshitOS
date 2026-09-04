# live-asm.spec -- M22 D2: on-machine assembler produces an ELF the on-machine loader runs.
# Staged source -> ASM.BIN -> PROG.ELF -> exec PROG.ELF -> exit status 71.

vgate_name live-asm "M22 D2: on-machine assembler + loader"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script1.txt <<'EOF'
ls
write PROG.S '_start:;mov x8, 3;mov x0, 71;svc 0'
exec ASM.BIN /host/PROG.S /host/PROG.ELF
EOF

vgate_file script2.txt <<'EOF'
ls
exec PROG.ELF
echo rx-asm-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script1.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'asm: wrote 96 bytes to /host/PROG.ELF' --script-expect 'tasks user-exec exited status=71' --timeout 90

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'PROG.S' 2
vgate_assert 01 serial-count 'write: ok' 1
vgate_assert 01 serial-count 'asm: wrote 96 bytes to /host/PROG.ELF' 1
vgate_assert 01 serial-count 'exec: loaded PROG.ELF size=' 1
vgate_assert 01 serial-count 'tasks user-exec exited status=71' 1
vgate_assert 01 serial-count 'tasks user-exec reaped' 2
vgate_assert 01 serial-exact 'rx-asm-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
