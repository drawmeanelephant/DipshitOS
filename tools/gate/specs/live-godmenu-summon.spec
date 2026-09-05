# live-godmenu-summon.spec -- M37 DQ1 God Menu summon + dynamic apps (issue #836)

vgate_name live-godmenu-summon "M37 DQ1 God Menu summon + dynamic apps"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --input-chords "ctrl-space,c,a,l,c,return,escape" --input-chords-after "notepad: ready" \
    --script-expect "wnd: god-menu exec verb=calc" --timeout 150

vgate_assert A serial-contains "wnd: god-menu open"
vgate_assert A serial-contains "wnd: god-menu exec verb=calc"
vgate_assert A serial-contains "wnd: god-menu close"
vgate_assert A serial-absent "[EXC] parking:"

vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
m = re.search(r'wnd: god-menu apps=([0-9]+)', ser)
assert m, "apps marker missing"
n = int(m.group(1))
assert 5 <= n <= 16, f"dynamic apps count {n} not in 5..16"
PY
