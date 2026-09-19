# live-wnd6-tray-drain.spec -- WMS6 Gate E: kernel-derived tray clock and WM-driven tray
# M66c (#1445): the client is NOTE.ELF, NOTEPAD.BIN's Go successor. The
# lifecycle vocabulary is shared by design (`note:` mirrors `notepad:`), so the
# assertions below moved by prefix alone. NOTEPAD.BIN is still built and still
# covered: five specs assert behaviour only the Zig app has (find/goto, theme
# tokens, the clipboard self-demo, the unsaved-decline contract), so retiring it
# is its own card rather than something this retarget assumes.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name live-wnd6-tray-drain "WMS6 Gate E: kernel-derived and WM-driven tray"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file sA.txt <<'EOF'
dui tray-state
echo tray-a-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTE.ELF
EOF

vgate_file s2-B.txt <<'EOF'
wm
dui tray-state
clip hello
echo tray-go
EOF

vgate_file s3-B.txt <<'EOF'
wm
dui tray-state
echo tray-done
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
    --script '$RUN_DIR/sA.txt' \
    --script-expect "echo tray-a-done" --timeout 180

vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui tray-state: clock=[0-9][0-9]:[0-9][0-9] clock_set=no', ser), "kernel clock check failed"
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY

# --- boot B: the WM-driven tray ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "note: ready" --script2-delay 15 \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "tray-go" --script3-delay 20 \
    --script-expect "tray-done" --timeout 240

vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'wnd: tray clock=', ser), "wnd: tray clock missing"
assert re.search(r'wm: .*tray=[1-9][0-9]*', ser), "wm: tray count missing"
assert re.search(r'dui tray-state: clock=[0-9][0-9]:[0-9][0-9] clock_set=yes', ser), "clock_set=yes missing"
assert re.search(r'dui tray-state: .*clip=yes clip_set=yes', ser), "clip=yes check failed"

mclk = re.findall(r'wnd: tray clock=([0-9][0-9]:[0-9][0-9])', ser)
sclk = re.findall(r'dui tray-state: clock=([0-9][0-9]:[0-9][0-9])', ser)
assert mclk and sclk and mclk[-1] == sclk[-1], f"clock mismatch: mclk={mclk} sclk={sclk}"

tray_vals = [int(x) for x in re.findall(r'tray=([0-9]+)', ser)]
assert len(tray_vals) >= 2 and tray_vals[-1] > tray_vals[0], f"tray counter did not grow: {tray_vals}"
PY
