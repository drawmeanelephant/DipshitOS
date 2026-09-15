# go-wm-seat.spec -- M57a/M57b (issues #1313/#1317) class-B gate: a Go WM
# registers the kernel render-server seat (slot 65), composites a blank
# desktop, and manages its OWN Go windows (rect/chrome/focus/close).
#
# user/go/gotabwm is the Go second seat. M57a: REGISTER (slot 65 cmd 1), a
# blank-desktop composite into the seam-B scanout grant (tagged sys_mmap), and
# a REQUEST_PRESENT loop paced by the kind-18 COMPOSITE_TICK. M57b: the seat's
# own window lifecycle — open, a chrome descriptor (cmd 2), a WM-proposed rect
# the KERNEL clamps to the scanout, focus gain/blur routed as WIN_FOCUS/
# WIN_BLUR, a close through the WM seam (cmd 13) whose WIN_CLOSE the owner
# receives, and the client-death rule (a window the process never closes is
# reaped by the kernel's exit seam).
#
# One headless boot arms the GPU, execs GOTABWM.ELF, queries the seat and the
# window registry while both are live, and lets the program exit cleanly (the
# kernel unregisters the seat and falls back to the shim). Serial markers are
# the proof; each is printed only after its syscall returned.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gotabwm-ok`, which only the
# script prints, and every stage gate waits on guest output the program and the
# kernel produce (`gotabwm: win focus`, `wm: unregistered, shim resumed`), so a
# program that never ran cannot pass.

vgate_name go-wm-seat "issues #1313/#1317 M57a+b: a Go WM registers the slot-65 seat, composites a blank desktop, and manages its own Go windows on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Phase 1: the boot default reports shim (the seat is opt-in), then opt in by
# hand. `exec` returns immediately, so the rest of the run is stage-gated on
# the program's own output.
vgate_file script.txt <<'EOF'
wm
exec GOTABWM.ELF
EOF

# Phase 2: forwarded while the program holds its own window and is WAITING for
# the blur — `dui focus 0` (the fixed terminal window) hands focus away, so the
# kernel routes WIN_BLUR to the seat. The `wm` + `dui` queries land while the
# seat and the window are both live.
vgate_file script2.txt <<'EOF'
wm
dui
dui focus 0
EOF

# Phase 3: after the program exits and the kernel unregisters the seat, the
# report is back to the shim and the window registry is back to its pre-program
# count (the leaked window reaped by the exit seam). The run ends on the
# harness echo.
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
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-ok' --timeout 240

# --- M57a: the seat and the blank desktop --------------------------------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
# The seat is opt-in: the boot default reports shim, and so does the run's
# closing `wm` query.
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
# The kernel's own report naming the live seat...
vgate_assert 01 serial-contains 'wm: registered pid='
vgate_assert 01 serial-contains 'wm: present_seq='
# ...and the clean teardown (the default falls back to the shim).
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-ok'

# --- M57b: the seat's own Go window lifecycle ----------------------------
# The program's window marker chain.
vgate_assert 01 serial-contains 'gotabwm: win open id='
vgate_assert 01 serial-contains 'gotabwm: win chrome'
vgate_assert 01 serial-contains 'gotabwm: win rect '
vgate_assert 01 serial-contains 'gotabwm: win focus'
vgate_assert 01 serial-contains 'gotabwm: win blur'
vgate_assert 01 serial-contains 'gotabwm: win close'
vgate_assert 01 serial-contains 'gotabwm: win gone'
vgate_assert 01 serial-contains 'gotabwm: win leak id='
# The kernel CLAMPED the WM's proposed 4000,3000 position to the 1280x720
# scanout: x is min(4000, 1280-256) = 1024, y is min(3000, 720-192) = 528,
# and the size is carried through unchanged.
vgate_assert 01 serial-contains 'gotabwm: win rect x=1024 y=528 w=256 h=192'
# While the seat's window is live the kernel registry counts 5 (the four fixed
# terminal/wallpaper/taskbar/dock windows + the seat's Go window)...
vgate_assert 01 serial-contains 'dui: windows=5 focused='
# ...and after the program exits it is back to 4: the window the seat never
# closed was reaped by the kernel's exit seam (M52 client-death discipline,
# no zombie window and no residue).
vgate_assert 01 serial-contains 'dui: windows=4 focused='

vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
