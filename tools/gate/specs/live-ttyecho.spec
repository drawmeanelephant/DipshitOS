# live-ttyecho.spec -- #1072 terminal (vt) seam pilot (class B, ADR 0020).
#
# TTYECHO.BIN (EL0) opens /dev/tty, attaches the serial console front-end via
# sys_tty_attach(1), and echoes. A line sent AFTER the attach must travel
# console RX -> terminal input queue -> the pilot -> terminal output ring ->
# console TX. Boot default is unchanged: nothing attaches until the pilot does.

vgate_name live-ttyecho "#1072 terminal seam: a userland process owns /dev/tty"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec TTYECHO.BIN
EOF

vgate_file script2.txt <<'EOF'
hello-seam
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'ttyecho: attached' --script-expect 'ttyecho: got hello-seam' --timeout 75

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'ttyecho: ready'
vgate_assert 01 serial-contains 'ttyecho: attached'
vgate_assert 01 serial-contains 'ttyecho: got hello-seam'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
