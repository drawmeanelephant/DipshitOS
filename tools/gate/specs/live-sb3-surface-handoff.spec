# live-sb3-surface-handoff.spec -- M33 SB3 (claim 3633) class-B gate:
#
# the window surface handoff, end to end on real VZ hardware (ADR 0016,
# seam B, issue #630). THIS is the milestone's parity gate: a migrated app
# renders into its shared surface with PLAIN STORES and the registered WM
# sees exactly those bytes — what the old kernel sys_win_fill path produced
# by construction (same B8G8R8X8 encoding, different destination memory).
#
# Two EL0 processes:

vgate_name live-sb3-surface-handoff "M33 SB3 (claim 3633) class-B gate:"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec SB3WM.BIN
exec SB3OWN.BIN
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script-expect 'sb3: wm done' --timeout 180

vgate_assert 01 serial-contains 'sb3: wm registered'
vgate_assert 01 serial-contains 'sb3: own opened'
vgate_assert 01 serial-contains 'sb3: own bound'
vgate_assert 01 serial-contains 'sb3: own stored'
vgate_assert 01 serial-contains 'sb3: wm-read=0xAB'
vgate_assert 01 serial-contains 'sb3: owner done'
vgate_assert 01 serial-contains 'sb3: wm done'
vgate_assert 01 serial-absent '[EXC] parking:'

