# live-ttyed.spec -- M45 card SH1 class-B gate (issue #1077, ADR 0021 D6).
#
# TTYED.BIN (EL0) drives `user/src/lib/tty.zig` on the terminal seam: it opens
# /dev/tty, attaches the serial console, and runs the line editor over the raw
# input queue. A scripted byte burst exercises editing LIVE — type "helo", Left
# + insert "l" -> "hello"; Up recalls "hello" from history; then Home/End with
# an insert -> "zxy!" — and each submitted line is echoed as `ttyed: line <x>`
# in ONE console write. Boot default unchanged: nothing attaches until TTYED.

vgate_name live-ttyed "#1077 SH1 terminal library: scripted line editing + history over /dev/tty"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec TTYED.BIN
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
# Raw keystrokes: "helo", Left, insert "l", Enter; Up (history), Enter;
# "xy", Home, insert "z", End, insert "!", Enter.
seq = b"helo\x1b[Dl\r\x1b[A\rxy\x1b[Hz\x1b[F!\r"
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(seq)
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit.bin' --script2-after 'ttyed: attached' --script-expect 'ttyed: line zxy!' --timeout 75

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'ttyed: ready'
vgate_assert 01 serial-contains 'ttyed: attached'
vgate_assert 01 serial-contains 'ttyed: line hello'
vgate_assert 01 serial-count 'ttyed: line hello' 2
vgate_assert 01 serial-contains 'ttyed: line zxy!'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
