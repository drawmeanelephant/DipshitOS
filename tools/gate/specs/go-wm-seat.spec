# go-wm-seat.spec -- M57a/b/c (issues #1313/#1317/#1318) class-B gate: a Go WM
# (GOTABWM.ELF) registers the kernel render-server seat (slot 65), composites a
# blank desktop, manages its OWN Go windows, and HOSTS GOCALC.ELF (M62h)
# plus leftover Zig NOTEPAD.BIN.
#
# M57a: REGISTER (slot 65 cmd 1), the seam-B scanout grant, and a REQUEST_PRESENT
# loop paced by the kind-18 COMPOSITE_TICK. M57b: the seat's own window
# lifecycle (open, chrome descriptor, a kernel-clamped rect, focus/blur, a
# WM-seam close, the client-death probe). M57c: interop — GOCALC.ELF
# discovers the seat by process name, declares over the WM_RPC
# mailbox, and is focused, given the full viewport, and closed by the seat.
# Zig CALC.BIN is gone (M62h / #1406).
#
# One headless boot arms the GPU, execs GOTABWM.ELF, queries the seat and the
# window registry while both are live, execs GOCALC.ELF under it, and lets the
# program exit cleanly (the kernel unregisters the seat, falling back to the
# shim). Serial markers are the proof; each is printed only after its syscall
# returned.
#
# M59 (issue #1298) note: the COMPILED default is now the Go seat, so this
# spec seeds `wm=none` in its share to keep what it actually proves -- the
# seat's explicit, opt-in registration path -- separate from the default flip
# (go-wm-default.spec owns that). Its "shim at boot" asserts are therefore
# about the seeded setting, not about the out-of-the-box boot.
# M63f (#1463): re-verified green after GOTABWM maxTicks 48. No HID here.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gotabwm-ok`, which only the
# script prints, and every stage gate waits on guest output the program, the
# kernel and the hosted app produce (`gotabwm: win focus`,
# `wm: unregistered, shim resumed`).
# M66c (#1445): the client is NOTE.ELF, NOTEPAD.BIN's Go successor. The
# lifecycle vocabulary is shared by design (`note:` mirrors `notepad:`), so the
# assertions below moved by prefix alone. NOTEPAD.BIN is still built and still
# covered: five specs assert behaviour only the Zig app has (find/goto, theme
# tokens, the clipboard self-demo, the unsaved-decline contract), so retiring it
# is its own card rather than something this retarget assumes.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name go-wm-seat "issues #1313/#1317/#1318 M57a+b+c: a Go WM registers the slot-65 seat and HOSTS GOCALC.ELF on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Phase 1: the seeded `wm=none` keeps this boot shim-only, then the seat is
# opted in explicitly.
vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

# Phase 2: forwarded while the program holds its own window and is WAITING for
# the blur. `dui focus 0` (the fixed terminal window) hands focus away, so the
# kernel routes WIN_BLUR to the seat. The `wm` + `dui` queries land while the
# seat's window is live (5 = the four fixed layers + the seat's Go window).
# Then GOCALC.ELF is exec'd under the Go seat.
vgate_file script2.txt <<'EOF'
wm
dui
dui focus 0
exec GOCALC.ELF
EOF

# Phase 3: after the program exits and the kernel unregisters the seat, the
# report is back to the shim and the registry is back to its pre-program count
# (the hosted app closed, the leaked probe window reaped).
vgate_file script3.txt <<'EOF'
wm
dui
echo rx-gotabwm-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
print("staged GOTABWM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTABWM.ELF")))
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
# M59 (issue #1298): the compiled default is the Go seat now. Seed `wm=none`
# so this boot composites via the shim and the seat arrives only where the
# script asks for it -- the point of THIS spec (go-wm-default.spec owns the
# default-flip proof). `none` is the documented shim-only seat value.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (wm=none: shim-only boot, explicit seat opt-in)")
PY

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

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-ok' --timeout 300

# --- M57a: the seat and the blank desktop --------------------------------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
# The seat is opt-in: the seeded `wm=none` leaves the boot shim-only (the
# autostart reports nothing for that seat), and the run's `wm` query before
# the exec and after the exit both report shim.
vgate_assert 01 serial-count 'wm: none (shim compositing)' 2
# The program's own marker chain (each printed after its syscall succeeded).
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: seat-taken'
vgate_assert 01 serial-contains 'gotabwm: scanout'
vgate_assert 01 serial-contains 'gotabwm: draw'
vgate_assert 01 serial-contains 'gotabwm: holding seat'
vgate_assert 01 serial-contains 'gotabwm: tick'
vgate_assert 01 serial-contains 'gotabwm: present'
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
# The kernel's own report naming the live seat, and the clean teardown.
vgate_assert 01 serial-contains 'wm: registered pid='
vgate_assert 01 serial-contains 'wm: present_seq='
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-ok'

# --- M57b: the seat's own Go window lifecycle ----------------------------
vgate_assert 01 serial-contains 'gotabwm: win open id='
vgate_assert 01 serial-contains 'gotabwm: win chrome'
vgate_assert 01 serial-contains 'gotabwm: win rect '
vgate_assert 01 serial-contains 'gotabwm: win focus'
vgate_assert 01 serial-contains 'gotabwm: win blur'
vgate_assert 01 serial-contains 'gotabwm: win close'
vgate_assert 01 serial-contains 'gotabwm: win gone'
vgate_assert 01 serial-contains 'gotabwm: win leak id='
# The kernel CLAMPED the WM's proposed 4000,3000 position to the 1280x720
# scanout: x is min(4000, 1280-256) = 1024, y is min(3000, 720-192) = 528.
vgate_assert 01 serial-contains 'gotabwm: win rect x=1024 y=528 w=256 h=192'
# While the seat's window is live the registry counts 5 (the four fixed
# terminal/wallpaper/taskbar/dock windows + the seat's Go window).
vgate_assert 01 serial-contains 'dui: windows=5 focused='

# --- M57c: GOCALC.ELF hosted by the Go seat --------------------------------
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'gotabwm: rpc declare id='
vgate_assert 01 serial-contains 'gocalc: declare accepted'
vgate_assert 01 serial-contains 'gocalc: present'
vgate_assert 01 serial-contains 'gotabwm: host focus id='
vgate_assert 01 serial-contains 'gotabwm: host view id='
vgate_assert 01 serial-contains 'gotabwm: host close id='
vgate_assert 01 serial-contains 'gocalc: close'
vgate_assert 01 serial-contains 'gotabwm: host done'
# No residue: the hosted app closed and the leaked probe window was reaped, so
# the registry is back to the four fixed layers only. The seat's own window sat
# at registry index 4 while it was live (one `dui[4]: user` row in the whole
# run) and there is no index-4 row after exit.
vgate_assert 01 serial-contains 'dui: windows=4 focused='
vgate_assert 01 serial-count 'dui[4]: user' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- M57c run 02: leftover Zig NOTEPAD -----------------------------------
# Same choreography, a leftover Zig tab-aware app. If GOCALC hosts and
# NOTEPAD does not (or vice versa) the interop would be app-specific.
vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
exec NOTE.ELF
EOF

vgate_file script3-02.txt <<'EOF'
dui
echo rx-gotabwm-np-ok
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-np-ok' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'exec: loaded NOTE.ELF'
# The same interop chain as CALC, for the second app.
vgate_assert 02 serial-contains 'gotabwm: rpc declare id='
vgate_assert 02 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert 02 serial-contains 'gotabwm: host focus id='
vgate_assert 02 serial-contains 'gotabwm: host view id='
vgate_assert 02 serial-contains 'note: resize relayout'
vgate_assert 02 serial-contains 'gotabwm: host close id='
vgate_assert 02 serial-contains 'note: win_close'
vgate_assert 02 serial-contains 'gotabwm: host done'
vgate_assert 02 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 02 serial-contains 'dui: windows=4 focused='
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
