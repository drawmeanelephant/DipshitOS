# live-snake.spec -- class-B gate: the VL6 snake game (tests/zc-corpus/
#
# snake-*.z) compiles IN-GUEST with ZC.BIN, runs as a windowed EL0 program,
# and its pixels are proven on the host framebuffer capture. First live RUN
# consumer of the VL6 GUI surface (the vl6 corpus fixture is compile-only)
# and of the raw zc.svc(21, &buf) event-poll seam (ADR 0009) from zc code.
#
# What the gate proves, in one display-backed boot:
#   1. ZC.BIN compiles the 4-file group in-guest (SNAKE.Z SLIB.Z EV.Z

vgate_name live-snake "class-B gate: the VL6 snake game (tests/zc-corpus/"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
ls
strace exec ZC.BIN SNAKE.Z SLIB.Z EV.Z FOOD.Z SNAKE.ELF
EOF

vgate_file script2.txt <<'EOF'
ls
exec SNAKE.ELF
echo rx-snake-ok
EOF

vgate_run 01 -- --display --screen '$RUN_DIR/snake-screen' --screenshot-after "snake-wait" --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "zc: successfully compiled in-guest" --script-expect "tasks user-exec exited status=72" --script-expect-tail 2 --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'SNAKE.Z'
vgate_assert 01 serial-contains 'SLIB.Z'
vgate_assert 01 serial-contains 'EV.Z'
vgate_assert 01 serial-contains 'FOOD.Z'
vgate_assert 01 serial-contains 'zc: successfully compiled in-guest'
vgate_assert 01 serial-contains 'exec: loaded SNAKE.ELF size='
vgate_assert 01 serial-contains 'snake-up'
vgate_assert 01 serial-contains 'snake-wait'
vgate_assert 01 serial-contains 'snake-move'
vgate_assert 01 serial-contains 'snake-over'
vgate_assert 01 serial-contains 'tasks user-exec exited status=72'
vgate_assert 01 serial-contains 'tasks user-exec reaped'
vgate_assert 01 serial-contains 'rx-snake-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'gpu: setup ok scanout='
