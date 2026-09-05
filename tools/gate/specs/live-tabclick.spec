# live-tabclick.spec -- M37 DQ3 tab mouse interaction (issue #839)

vgate_name live-tabclick "M37 DQ3 tab mouse interaction: click switches, × detaches, drag detaches"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_allow_rc A 0 1
vgate_allow_rc B 0 1
vgate_allow_rc C 0 1

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
exec TABHOLD.BIN
EOF

# --- boot A: click cell body → activate ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --pointer-virtio "440,82,c" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240

vgate_assert A serial-contains "wnd: tab-activate id=3"
vgate_assert A python <<'PY'
import os
# Reset share state between boots
p = os.path.join(os.environ["VG_SHARE"], "WINDOWS.SAV")
if os.path.exists(p): os.remove(p)
PY

# --- boot B: click × → detach, no drag ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --pointer-virtio "561,82,c" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240

vgate_assert B serial-contains "wnd: tab-detach child=3"
vgate_assert B serial-absent "wnd: tab-drag"
vgate_assert B python <<'PY'
import os
p = os.path.join(os.environ["VG_SHARE"], "WINDOWS.SAV")
if os.path.exists(p): os.remove(p)
PY

# --- boot C: drag out → detach at drop ---
vgate_run C -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --pointer-virtio "440,82,d;440,200,u" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240

vgate_assert C serial-contains "wnd: tab-drag"
vgate_assert C serial-contains "wnd: tab-detach child=3"
