# live-sb2-shared-anon.spec -- M33 SB2 (claim 8878) class-B gate: the
#
# shared-anonymous mmap capability end to end on real VZ hardware (ADR 0016).
#
# Two EL0 processes map ONE physical region through sys_mmap (slot 63) with
# the M33_MAP_SHARED flag (bit 16):
#   * SB2WM.BIN  — the WM (peer) half: registers as the WM server (slot 65),
#     receives the owner's {pid, handle, magic} handshake over the mailbox,
#     attaches the surface READ-ONLY by handle (EL0-RO sw_cow leaf in ITS OWN

vgate_name live-sb2-shared-anon "M33 SB2 (claim 8878) class-B gate: the"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec SB2WM.BIN
exec SB2OWN.BIN
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script-expect 'sb2: wm done' --timeout 180

vgate_assert 01 serial-contains 'sb2: wm registered'
vgate_assert 01 serial-contains 'sb2: own created'
vgate_assert 01 serial-contains 'sb2: wm-read=0xAB'
vgate_assert 01 serial-contains 'sb2: own ack'
vgate_assert 01 serial-contains 'sb2: owner done'
vgate_assert 01 serial-contains 'sb2: wm-reattach=EFAULT'
vgate_assert 01 serial-contains 'sb2: wm done'
vgate_assert 01 serial-absent '[EXC] parking:'

