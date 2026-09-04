# live-symbols.spec -- M22 D3: symbolized crash reports.
# CRASH.ELF's symtab populates the kernel symbol table; its BRK fault
# produces a status-139 tombstone; 'crash' resolves the PC to '(in crasher+0x4)'.

vgate_name live-symbols "M22 D3: symbolized crash reports"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec CRASH.ELF
echo sym-mid
EOF

vgate_file script2.txt <<'EOF'
sym
crash
echo rx-sym-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'tasks user-exec exited status=139' --script-expect 'rx-sym-ok' --timeout 90

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'CRASH.ELF' 2
vgate_assert 01 serial-count 'exec: loaded CRASH.ELF size=' 1
vgate_assert 01 serial-count 'tasks user-exec exited status=139' 1
vgate_assert 01 serial-count 'crasher addr=0x0000000000400000' 1
vgate_assert 01 serial-count '(in crasher+0x4)' 1
vgate_assert 01 serial-exact 'rx-sym-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
