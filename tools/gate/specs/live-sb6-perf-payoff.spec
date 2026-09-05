# live-sb6-perf-payoff.spec -- M33 SB6 (claim 6864) class-B gate:
#
# measure seam B against the WMS9 baselines, live on real VZ hardware.
#
# ONE headless boot, THREE scripted programs, TWO snapshots:
#   Phase 1 (the "before" control):  SB6OLD.BIN opens a 256x192 user window
#     and renders an 8x8 grid (static + 8 dynamic redraws) through the
#     FROZEN per-rect path — 576 `sys_win_fill` (slot 13) SVCs + 9
#     `sys_win_present` (slot 14) SVCs, each present kernel-blitted.

vgate_name live-sb6-perf-payoff "M33 SB6: seam-B perf-payoff on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec SB6WM.BIN
exec SB6OLD.BIN
exec SB6NEW.BIN
EOF

vgate_file script2.txt <<'EOF'
dui
syscalls
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'timer heartbeat ticks=45' --script-expect '13 sys_win_fill calls=576' --timeout 180

vgate_assert 01 serial-contains 'sb6: wm registered'
vgate_assert 01 serial-contains 'sb6: wm scanout=1'
vgate_assert 01 serial-contains 'sb6: old fills=576'
vgate_assert 01 serial-contains 'sb6: old done'
vgate_assert 01 serial-contains 'sb6: new ready'
vgate_assert 01 serial-contains 'sb6: new bound'
vgate_assert 01 serial-contains 'sb6: new fills=0 stores=ok'
vgate_assert 01 serial-contains 'sb6: new done'
vgate_assert 01 serial-contains 'sb6: wm bytes=196608'
vgate_assert 01 serial-contains 'sb6: wm readback=0x6B'
vgate_assert 01 serial-contains 'sb6: wm present'
vgate_assert 01 serial-contains 'sb6: wm done'
vgate_assert 01 serial-contains '13 sys_win_fill calls=576'
vgate_assert 01 serial-contains 'dui: windows='
vgate_assert 01 serial-absent 'sb6: wm register-fail'
vgate_assert 01 serial-absent 'sb6: wm scanout-fail'
vgate_assert 01 serial-absent 'sb6: wm attach-fail'
vgate_assert 01 serial-absent 'sb6: wm compose-fail'
vgate_assert 01 serial-absent 'sb6: old open-fail'
vgate_assert 01 serial-absent 'sb6: new open-fail'
vgate_assert 01 serial-absent 'sb6: new bind-fail'
vgate_assert 01 serial-absent 'sb6: new no-wm'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, sys, re
ser = open(os.environ["VG_SER"]).read()
for line in ser.splitlines():
    if "dui: windows=" in line:
        m_b = re.search(r'blits=([0-9]+)', line)
        m_s = re.search(r'skips=([0-9]+)', line)
        if m_b and m_s and int(m_b.group(1)) >= 9 and int(m_s.group(1)) >= 9:
            sys.exit(0)
sys.exit(1)
PY
