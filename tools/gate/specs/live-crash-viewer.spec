# live-crash-viewer.spec -- M22 D11: crash report viewer on VZ.
# Executes CRASH.ELF, then 'crash 1' renders the detailed tombstone
# with the resolved symbol '(in crasher+0x4)' and the serial snapshot.

vgate_name live-crash-viewer "M22 D11: crash report viewer on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec CRASH.ELF
echo cv-mid
EOF

vgate_file script2.txt <<'EOF'
crash 1
echo rx-crashview-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'tasks user-exec exited status=139' --script-expect 'rx-crashview-ok' --timeout 90

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-contains 'exited status=139'
vgate_assert 01 serial-contains 'VirelaiOS Crash Tombstone'
vgate_assert 01 serial-contains '(in crasher+0x4)'
vgate_assert 01 serial-contains '--- Last Serial Output ---'
vgate_assert 01 serial-exact 'rx-crashview-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
