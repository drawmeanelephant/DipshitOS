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

# M52 card 3 (#1240): the client's death (the ordinary exit path here) must
# leave NO zombie window behind. The probe runs after the WM's own exit —
# i.e. after the owner's exit already closed its surface-backed window — and
# dumps the kernel registry, where a zombie row would still be composited
# from the region the revoke freed.
vgate_file s2.txt <<'EOF'
dui
echo sb3-zombie-probe-done
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/s2.txt' --script2-after 'sb3: wm done' --script2-delay 5 --script-expect 'sb3-zombie-probe-done' --timeout 240

vgate_assert 01 serial-contains 'sb3: wm registered'
vgate_assert 01 serial-contains 'sb3: own opened'
vgate_assert 01 serial-contains 'sb3: own bound'
vgate_assert 01 serial-contains 'sb3: own stored'
vgate_assert 01 serial-contains 'sb3: wm-read=0xAB'
vgate_assert 01 serial-contains 'sb3: owner done'
vgate_assert 01 serial-contains 'sb3: wm done'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
# Non-vacuity: the app really opened a user window (the kernel's own
# open-attribution marker, one line per real open), BOUND a surface as its
# back-buffer, and the WM read those bytes through its RO mirror — all
# BEFORE the owner's death and the probe.
i_open = ser.index("open: id=2 owner=2")
i_bound = ser.index("sb3: own bound", i_open)
i_read = ser.index("sb3: wm-read=0xAB", i_bound)
i_owner_done = ser.index("sb3: owner done", i_read)
i_wm_done = ser.index("sb3: wm done", i_owner_done)
i_probe = ser.index("dui: windows=", i_wm_done)
i_end = ser.index("sb3-zombie-probe-done", i_probe)
# The probe's registry block: `dui: windows=N` then one `dui[i]: <title>
# <kind> rect=...` row per window. The dead owner's surface-backed window
# must be GONE — a zombie row would still be composited from the region the
# revoke freed.
block = ser[i_probe:i_end].splitlines()
rows = [l for l in block if re.match(r'dui\[[0-9]+\]: ', l)]
m = re.search(r'dui: windows=([0-9]+)', block[0])
assert m, "no windows= count"
assert int(m.group(1)) == len(rows) and rows, "windows= disagrees with the rows"
zombies = [l for l in rows if " user user " in l]
assert not zombies, f"zombie window after the owner's death: {zombies}"
PY

