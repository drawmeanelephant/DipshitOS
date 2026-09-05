# live-sexiburger.spec -- Milestone 19 Sexiburger God Menu on VZ

vgate_name live-sexiburger "Milestone 19 Sexiburger God Menu on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec SEXIBURG.BIN
EOF

vgate_file script2.txt <<'EOF'
echo sexiburger-live-ok
EOF

vgate_run 01 -- \
    --display --screen '$RUN_DIR/gpu-screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script-after "tasks user-el0 exited status=7" \
    --input-chords "ctrl-b" \
    --input-chords-after "sexiburger: ready" \
    --screenshot-after "sexiburger: ready" \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after "timer heartbeat ticks=15" \
    --script-expect "sexiburger-live-ok" \
    --timeout 45

vgate_assert 01 serial-contains "VirelaiOS kernel has seized control."
vgate_assert 01 serial-contains "sexiburger: ready"
vgate_assert 01 serial-contains "sexiburger-live-ok"
vgate_assert 01 serial-absent "[EXC] parking:"
