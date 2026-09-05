# live-wm7-gateb.spec -- WMS7 Gate B (issue #627): toolkit round-trip and no-wm fallback

vgate_name live-wm7-gateb "live-wm7-gateb: toolkit round-trip and no-wm fallback"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
exec WMRPC.BIN
echo wmipc-a2-go
EOF

vgate_file s3-A.txt <<'EOF'
dui
wm
echo wmipc-a2-done
EOF

vgate_file sB.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file s2-B.txt <<'EOF'
exec WMRPC.BIN
EOF

vgate_file s3-B.txt <<'EOF'
dui
echo wmfail-b-done
EOF

vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 6 \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "wmrpc: done" --script3-delay 8 \
    --script-expect "wmipc-a2-done" --timeout 240

vgate_assert A serial-contains 'wnd: mail kind=1 id=2 seq=1 applied=yes'
vgate_assert A serial-contains 'wnd: mail kind=2 id=2 seq=2 applied=yes title=wm-rpc'
vgate_assert A serial-contains 'wmrpc: raise-ack applied=yes'
vgate_assert A serial-contains 'wmrpc: config-ack applied=yes'
vgate_assert A serial-contains 'wnd: present'
vgate_assert A serial-absent '[EXC] parking:'
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui: windows=[0-9]+ focused=2', ser), "focused check failed"
assert re.search(r'dui\[[0-9]+\]: user user rect=40,40,360,260', ser), "rect check failed"
PY

vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/sB.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "notepad: open" --script2-delay 5 \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "wmrpc: no-wm" --script3-delay 6 \
    --script-expect "wmfail-b-done" --timeout 240

vgate_assert B serial-contains 'wmrpc: no-wm'
vgate_assert B serial-contains 'wmrpc: fallback raise=ok move=ok'
vgate_assert B serial-absent '[EXC] parking:'
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui\[[0-9]+\]: user user rect=40,40,', ser), "moved rect check failed"
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY
