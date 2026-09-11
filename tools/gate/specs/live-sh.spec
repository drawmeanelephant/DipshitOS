# live-sh.spec -- M45 card SH2 class-B gate (issue #1078, ADR 0021 D2/D3).
#
# SH.BIN (EL0) opens /dev/tty, attaches the serial console, prompts, and
# dispatches through the pure lib/shell.zig core. A scripted burst proves the
# core live: `echo` (builtin), `cd /data` + `$PWD` expansion, external
# `status43` resolved case-insensitively (status43 -> STATUS43.BIN) and run
# foreground, then Up-history re-runs it (status43: alive twice). Markers are
# single writes. Boot default unchanged: nothing attaches until SH.BIN does.

vgate_name live-sh "#1078 SH2 userland shell: builtins, cd, external app + Up-history over /dev/tty"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec SH.BIN
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
# echo sh-echo-ok; cd /data; echo PWD=$PWD; run status43; then Up + Enter to
# recall and re-run the last command from history.
seq = b"echo sh-echo-ok\rcd /data\recho PWD=$PWD\rstatus43\r\x1b[A\r"
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(seq)
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit.bin' --script2-after 'sh: attached' --script-expect 'status43: alive' --script-expect-tail 16 --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'sh: ready'
vgate_assert 01 serial-contains 'sh: attached'
vgate_assert 01 serial-contains 'sh-echo-ok'
vgate_assert 01 serial-contains 'PWD=/data'
vgate_assert 01 serial-contains 'status43: alive'
vgate_assert 01 serial-count 'status43: alive' 2
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
