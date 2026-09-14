# live-wnd-server.spec -- M32 WMS3: long-lived EL0 WM server (WND.BIN) on VZ
# M52 card 2 (#1239): run 02 holds a WM-DECIDED capture (the tray tooltip,
# cmd 8) and then kills the WM — the seat release must drop it, so the
# resumed shim never inherits a modality it no longer decides.

vgate_name live-wnd-server "M32 WMS3: long-lived EL0 WM server on VZ"
vgate_share seed
# GF6 closeout (issue #1020): seed arms the host file channel, whose
# --cvc-file implies the full custom-virtio device shape — SPIKE-only.
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
wm
wnd start
EOF

vgate_file script2.txt <<'EOF'
wm
wnd
kill WND.BIN
EOF

vgate_file script3.txt <<'EOF'
wm
wnd start
echo rx-wnd-server-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'wnd: present' --script3 '$RUN_DIR/script3.txt' --script3-after 'tasks user-exec reaped' --script-expect 'rx-wnd-server-ok' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-count 'wm: none (shim compositing)' 2
vgate_assert 01 serial-count 'wnd: registered' 2
vgate_assert 01 serial-contains 'wnd: present'
vgate_assert 01 serial-contains 'wm: registered pid='
vgate_assert 01 serial-contains 'tasks user-exec exited status=137'
vgate_assert 01 serial-contains 'tasks user-exec reaped'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-wnd-server-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

# --- M52 card 2 (#1239): the seat release drops a WM-held capture ---
# The WM decides the tray tooltip from its kind-19 stream (cmd 8 TOOLTIP);
# the kernel holds it. Killing the WM must release it, not strand it: with
# the shim decision drained in WMS6 there is no shim path left to hide it.

vgate_file script-c.txt <<'EOF'
wm
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-c.txt <<'EOF'
wm
dui tooltip-state
kill WND.BIN
EOF

vgate_file s3-c.txt <<'EOF'
dui tooltip-state
wm
echo kill-capture-done
EOF

vgate_run 02 -- --screen '$RUN_DIR/screen-c' --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-c.txt' \
    --pointer-virtio '1240,700' --pointer-virtio-after 'wnd: present' \
    --script2 '$RUN_DIR/s2-c.txt' --script2-after 'wnd: tooltip' --script2-delay 10 \
    --script3 '$RUN_DIR/s3-c.txt' --script3-after 'tasks user-exec reaped' --script3-delay 10 \
    --script-expect 'kill-capture-done' --timeout 260

vgate_assert 02 serial-contains 'wnd: tooltip'
vgate_assert 02 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os
ser = open(os.environ["VG_SER"]).read()
# Non-vacuity + ordering: the WM held the tooltip (visible=yes) BEFORE the
# kill was armed, and a post-reap probe observes it released (visible=no).
# A boot that never showed the tooltip cannot satisfy this.
i_yes = ser.index("dui tooltip-state: visible=yes text=Clock")
i_kill = ser.index("kill: WND.BIN armed")
i_no = ser.index("dui tooltip-state: visible=no")
assert i_yes < i_kill < i_no, "the WM's tooltip capture survived the seat release"
PY
