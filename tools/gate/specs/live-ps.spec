# live-ps.spec -- vgate pilot (seeded share + display/input + repeat):
# the process status table, both halves. Mirrors
# tools/verify-live-ps.sh (M22 D6, issue #329): monitor `ps` prints the
# table, COUNTER.BIN gives the windowed viewer something to show, PS.BIN
# proves the launch chain, shell stays responsive.

vgate_name live-ps "process status table + windowed viewer"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS
vgate_note "script: ps / exec COUNTER.BIN / ps / exec PS.BIN / echo rx-ps-ok"

vgate_file script.txt <<'EOF'
ps
exec COUNTER.BIN
ps
exec PS.BIN
echo rx-ps-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --display --input --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'PID  NAME' 2
vgate_assert 01 serial-count 'COUNTER.BIN' 3
vgate_assert 01 serial-exact 'ps: ready' 1
vgate_assert 01 serial-exact 'rx-ps-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
