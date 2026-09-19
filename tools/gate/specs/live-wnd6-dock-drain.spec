# live-wnd6-dock-drain.spec -- WMS6 Gate D: shim and WM-driven dock click
# M66c (#1445): the client is NOTE.ELF, NOTEPAD.BIN's Go successor. The
# lifecycle vocabulary is shared by design (`note:` mirrors `notepad:`), so the
# assertions below moved by prefix alone. NOTEPAD.BIN is still built and still
# covered: five specs assert behaviour only the Zig app has (find/goto, theme
# tokens, the clipboard self-demo, the unsaved-decline contract), so retiring it
# is its own card rather than something this retarget assumes.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name live-wnd6-dock-drain "WMS6 Gate D: shim and WM-driven dock click"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTE.ELF
EOF

vgate_file s2-A.txt <<'EOF'
dui minimize 2
dui
echo dock-a-go
EOF

vgate_file s3-A.txt <<'EOF'
dui
echo shim-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTE.ELF
EOF

vgate_file s2-B.txt <<'EOF'
dui minimize 2
dui
wm
echo dock-go
EOF

vgate_file s3-B.txt <<'EOF'
dui
dui tooltip-state
wm
echo dock-done
EOF

# --- boot A: shim regression (no WM) ---
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "NOTE.ELF")
if not os.path.exists(src):
    sys.exit("NOTE.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-note.sh")
shutil.copy(src, os.path.join(share, "NOTE.ELF"))
print("staged NOTE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "NOTE.ELF")))
PY

vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "note: ready" --script2-delay 20 \
    --pointer-virtio "12,18,c" --pointer-virtio-after "dock-a-go" \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "dock-a-go" --script3-delay 8 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-contains "dui minimize: minimized id=2"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui: windows=[0-9]+ focused=2', ser), "focused=2 check failed"
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY

# --- boot B: the WM-driven dock ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "note: ready" --script2-delay 20 \
    --pointer-virtio "12,24;12,18,c" --pointer-virtio-after "dock-go" \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "dock-go" --script3-delay 20 \
    --script-expect "dock-done" --timeout 260

vgate_assert B serial-contains "wnd: dock idx=0"
vgate_assert B serial-contains "wnd: tooltip"
vgate_assert B serial-contains "dui tooltip-state: visible=yes text=Calc"
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dock=[1-9][0-9]*', ser), "dock check failed"
assert re.search(r'dui: windows=[0-9]+ focused=2', ser), "focused=2 check failed"
PY
