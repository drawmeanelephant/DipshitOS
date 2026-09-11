# live-sh5.spec -- M45 card SH5 class-B gate (issue #1081, ADR 0021 D4/D6).
#
# A real script file on the share exercises the M19 scripting port end to end:
# arithmetic, for, if/else, a function with an argument, command substitution,
# and &&/|| short-circuit. The gate writes SCRIPT.SH into the share during
# setup, execs SH.BIN, and `source`s the script. Assertions are output-only
# markers (a heartbeat can split a typed echo). Boot default unchanged.

vgate_name live-sh5 "#1081 SH5 scripting: arith, for, if, fn, \$(), &&/|| from a share script"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec SH.BIN
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
lines = [
    "echo SCRIPT-OK",
    "set X=$(( (2+3)*4 ))",
    "echo ARITH=$X",
    "for n in a b c; do echo ITEM-$n; done",
    "if true; then echo IF-YES; else echo IF-NO; fi",
    "fn greet(name) { echo HELLO-$name }",
    "greet world",
    "echo SUB=$(echo INNER)",
    "true && echo CHAIN-AND",
    "false || echo CHAIN-OR",
    "false && echo CHAIN-NOPE",
]
with open(os.path.join(run, "share", "SCRIPT.SH"), "w") as f:
    f.write("\n".join(lines) + "\n")
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(b"source SCRIPT.SH\r")
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit.bin' --script2-after 'sh: attached' --script-expect 'CHAIN-OR' --script-expect-tail 5 --timeout 75

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'sh: ready'
vgate_assert 01 serial-contains 'sh: attached'
vgate_assert 01 serial-contains 'SCRIPT-OK'
vgate_assert 01 serial-contains 'ARITH=20'
vgate_assert 01 serial-contains 'ITEM-a'
vgate_assert 01 serial-contains 'ITEM-c'
vgate_assert 01 serial-contains 'IF-YES'
vgate_assert 01 serial-absent 'IF-NO'
vgate_assert 01 serial-contains 'HELLO-world'
vgate_assert 01 serial-contains 'SUB=INNER'
vgate_assert 01 serial-contains 'CHAIN-AND'
vgate_assert 01 serial-contains 'CHAIN-OR'
vgate_assert 01 serial-absent 'CHAIN-NOPE'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
