# live-wnd-server.spec -- M32 WMS3: long-lived EL0 WM server (WND.BIN) on VZ

vgate_name live-wnd-server "M32 WMS3: long-lived EL0 WM server on VZ"
vgate_share seed

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
