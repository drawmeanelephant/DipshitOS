# live-wnd8-ptr-drag-delete.spec -- WMS8 Gate 6: kernel title-bar drag decision deleted
# M66c (#1445): the client is NOTE.ELF, NOTEPAD.BIN's Go successor. The
# lifecycle vocabulary is shared by design (`note:` mirrors `notepad:`), so the
# assertions below moved by prefix alone. NOTEPAD.BIN is still built and still
# covered: five specs assert behaviour only the Zig app has (find/goto, theme
# tokens, the clipboard self-demo, the unsaved-decline contract), so retiring it
# is its own card rather than something this retarget assumes.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name live-wnd8-ptr-drag-delete "WMS8 Gate 6: kernel title-bar drag decision deleted"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTE.ELF
EOF

vgate_file s2-A.txt <<'EOF'
dui
echo drag-a
EOF

vgate_file s3-A.txt <<'EOF'
dui
echo done-a
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTE.ELF
EOF

vgate_file s2-B.txt <<'EOF'
dui
wm
echo drag-b
EOF

vgate_file s3-B.txt <<'EOF'
dui
wm
echo done-b
EOF

# --- boot A: shim (no WM) -- title-bar drag does not move window ---
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
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "note: ready" --script2-delay 2 \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "drag-a" --script3-delay 45 \
    --pointer-virtio "300,64,d;350,80;400,100;450,120;500,300,u" --pointer-virtio-after "note: ready" \
    --script-expect "echo done-a" --timeout 240

vgate_assert A serial-contains "rect=56,56,512,384"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r'(panic|abort|kernel fault)', ser), "fault in serial A"
PY

# --- boot B: WM registered -- WM owns the drag ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "note: ready" --script2-delay 2 \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "drag-b" --script3-delay 45 \
    --pointer-virtio "300,64,d;350,80;400,100;450,120;500,300,u" --pointer-virtio-after "note: ready" \
    --script-expect "done-b" --timeout 240

vgate_assert B serial-contains "wnd: grab"
vgate_assert B serial-contains "wnd: drag"
vgate_assert B serial-contains "wnd: drop"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'wm: ptr_fan=[1-9][0-9]*', ser), "ptr_fan check failed"
assert "rect=56,56,512,384" in ser, "initial rect missing"
lines = [l for l in ser.splitlines() if "user user rect=" in l]
assert len(lines) >= 1, "no user rect line found"
last = lines[-1]
assert "rect=56,56,512,384" not in last, f"window did not move: {last}"
PY
