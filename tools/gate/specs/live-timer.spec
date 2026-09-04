# live-timer.spec -- real CNTP PPI delivery through the EL1 IRQ vector.
# Mirrors tools/verify-live-timer.sh (claim 9187): five IRQ-serviced ticks,
# no fallback polls, shell alive throughout.

vgate_name live-timer "CNTP PPI delivery, 5 IRQ ticks, no polls"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_note "script: timer / echo rx-timer-ok; expect heartbeat ticks=5 irq=5 poll=0"

vgate_file script.txt <<'EOF'
timer
echo rx-timer-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'timer heartbeat ticks=5 irq=5 poll=0' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'interrupts: gic='
vgate_assert 01 serial-contains 'timer: armed=1'
vgate_assert 01 serial-contains 'rx-timer-ok'
vgate_assert 01 serial-contains 'timer irq delivered ppi=0x1e irq_ticks=1'
vgate_assert 01 serial-contains 'timer heartbeat ticks=5 irq=5 poll=0'
