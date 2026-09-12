# live-term-net.spec -- M46 RC3b class-B gate (issue #1104, ADR 0020 B6).
#
# TERM.BIN (the windowed shell) accepts the same net front-end argument as
# SH.BIN: `TERM.BIN net [port] [secret] [allow-ip]` attaches selector 3
# instead of the window. The host initiates via the runner's
# --net-tcp-connect seam; the shell core runs over the terminal and replies
# on the TCP connection. M50 TS4 (#1138): explicit `open` mode (no credential
# in the store on this share; the default posture refuses to listen). Boot default is unchanged — TERM.BIN with no args is
# still the window front-end (live-term).

vgate_name live-term-net "M46 RC3b: TERM.BIN hosts the net front-end (selector 3) (#1104)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
net ip 10.0.0.1
exec TERM.BIN net 2323 open
EOF

vgate_file payload.txt <<'EOF'
help
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' \
    --script '$RUN_DIR/script.txt' \
    --net-tcp-connect '10.0.0.1:2323:$RUN_DIR/payload.txt' \
    --net-tcp-connect-after 'term: remote on' \
    --net-tcp-connect-close-after 'builtins:' \
    --script-expect 'tty net: detached' \
    --timeout 120

vgate_assert 01 serial-contains 'term: ready'
vgate_assert 01 serial-contains 'term: remote on 2323'
vgate_assert 01 output-contains 'builtins:'
vgate_assert 01 serial-contains 'tty net: detached'
vgate_assert 01 serial-absent '[EXC] parking:'
