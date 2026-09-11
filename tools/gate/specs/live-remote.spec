# live-remote.spec -- M45 card SH7 class-B gate (issue #1083, ADR 0020 B).
#
# A guest shell hosts the NET front-end (selector 3): SH.BIN opens /dev/tty,
# enters LISTEN on port 2323 via sys_tty_attach(3, port), and runs the shared
# shell core. The kernel pumps raw bytes between the terminal rings and the
# single bounded TCP connection. Because kernel/src/tcp.zig has NO loopback
# and the guest is behind VZ NAT, the HOST initiates the connection via the
# runner's --net-tcp-connect seam: SYN -> handshake -> `help` payload -> the
# shell's reply -> FIN, which auto-detaches the terminal (B4).
#
# Boot default unchanged: nothing attaches until SH.BIN is asked with the
# `net` argument; the untouched serial default is the other live-sh gates.

vgate_name live-remote "#1083 SH7 remote front-end: host->guest inbound TCP drives the shell (selector 3)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
net ip 10.0.0.1
exec SH.BIN net 2323
EOF

vgate_file payload.txt <<'EOF'
help
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' \
    --script '$RUN_DIR/script.txt' \
    --net-tcp-connect '10.0.0.1:2323:$RUN_DIR/payload.txt' \
    --net-tcp-connect-after 'sh: remote' \
    --net-tcp-connect-close-after 'builtins:' \
    --script-expect 'tty net: detached' \
    --timeout 120

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'sh: ready'
vgate_assert 01 serial-contains 'sh: remote on 2323'
vgate_assert 01 serial-contains 'tty net: detached'
vgate_assert 01 output-contains 'NET-TCP-CONNECT: sent SYN'
vgate_assert 01 output-contains 'NET-TCP-CONNECT: handshake complete'
vgate_assert 01 output-contains 'builtins:'
vgate_assert 01 output-contains 'NET-TCP-CONNECT: sent FIN'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
