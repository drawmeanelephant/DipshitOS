# go-wm-seat.spec -- M57a/b/c (issues #1313/#1317/#1318) class-B gate: a Go WM
# (GOTABWM.ELF) registers the kernel render-server seat (slot 65), composites a
# blank desktop, manages its OWN Go windows, and HOSTS UNMODIFIED Zig apps.
#
# M57a: REGISTER (slot 65 cmd 1), the seam-B scanout grant, and a REQUEST_PRESENT
# loop paced by the kind-18 COMPOSITE_TICK. M57b: the seat's own window
# lifecycle (open, chrome descriptor, a kernel-clamped rect, focus/blur, a
# WM-seam close, the client-death probe). M57c: interop - an unmodified Zig app
# (CALC.BIN) discovers the seat by process name, declares over the WM_RPC
# mailbox, and is focused, given the full viewport, and closed by the seat, with
# the SAME app-side markers the TABWM parity gate (live-tabwm-close.spec)
# asserts.
#
# One headless boot arms the GPU, execs GOTABWM.ELF, queries the seat and the
# window registry while both are live, execs CALC.BIN under it, and lets the
# program exit cleanly (the kernel unregisters the seat, falling back to the
# shim). Serial markers are the proof; each is printed only after its syscall
# returned.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gotabwm-ok`, which only the
# script prints, and every stage gate waits on guest output the program, the
# kernel and the hosted Zig app produce (`gotabwm: win focus`,
# `wm: unregistered, shim resumed`).

vgate_name go-wm-seat "issues #1313/#1317/#1318 M57a+b+c: a Go WM registers the slot-65 seat and HOSTS an unmodified Zig app on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Phase 1: the boot default reports shim (the seat is opt-in), then opt in.
vgate_file script.txt <<'EOF'
wm
exec GOTABWM.ELF
EOF

# Phase 2: forwarded while the program holds its own window and is WAITING for
# the blur. `dui focus 0` (the fixed terminal window) hands focus away, so the
# kernel routes WIN_BLUR to the seat. The `wm` + `dui` queries land while the
# seat's window is live (5 = the four fixed layers + the seat's Go window).
# Then the UNMODIFIED Zig app is exec'd under the Go seat.
vgate_file script2.txt <<'EOF'
wm
dui
dui focus 0
exec CALC.BIN
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

# --- M57c: an UNMODIFIED Zig app hosted by the Go seat -------------------
# The kernel loaded the untouched Zig binary.
vgate_assert 01 serial-contains 'exec: loaded CALC.BIN'
# The app found the Go seat BY NAME and its declare round-tripped: the ack
# carried applied=1, which is what makes it print this.
vgate_assert 01 serial-contains 'gotabwm: rpc declare id='
vgate_assert 01 serial-contains 'calc: tab-aware (full-viewport)'
# The seat focused+raised it through the kernel's own primitive...
vgate_assert 01 serial-contains 'gotabwm: host focus id='
# ...and proposed the full viewport, which the app observed as WIN_RESIZE and
# relaid out. These are the SAME app-side markers the TABWM parity gate
# (live-tabwm-close.spec) asserts, on the same exercised path.
vgate_assert 01 serial-contains 'gotabwm: host view id='
vgate_assert 01 serial-contains 'calc: resize relayout'
# The seat closed it through the WM seam: the app received the real WIN_CLOSE.
vgate_assert 01 serial-contains 'gotabwm: host close id='
vgate_assert 01 serial-contains 'calc: win_close'
vgate_assert 01 serial-contains 'gotabwm: host done'
# No residue: the hosted app closed and the leaked probe window was reaped, so
# the registry is back to the four fixed layers only. The seat's own window sat
# at registry index 4 while it was live (one `dui[4]: user` row in the whole
# run) and there is no index-4 row after exit.
vgate_assert 01 serial-contains 'dui: windows=4 focused='
vgate_assert 01 serial-count 'dui[4]: user' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- M57c run 02: the SECOND unmodified Zig app (NOTEPAD) ----------------
# Same choreography, the other tab-aware app. NOTEPAD links the same
# lib/tabapp.zig: if CALC hosts and NOTEPAD does not (or vice versa) the
# interop would be app-specific rather than seat-wide, so both are gated.
vgate_file script-02.txt <<'EOF'
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
exec NOTEPAD.BIN
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
vgate_assert 02 serial-contains 'exec: loaded NOTEPAD.BIN'
# The same interop chain as CALC, for the second app.
vgate_assert 02 serial-contains 'gotabwm: rpc declare id='
vgate_assert 02 serial-contains 'notepad: tab-aware (full-viewport)'
vgate_assert 02 serial-contains 'gotabwm: host focus id='
vgate_assert 02 serial-contains 'gotabwm: host view id='
vgate_assert 02 serial-contains 'notepad: resize relayout'
vgate_assert 02 serial-contains 'gotabwm: host close id='
vgate_assert 02 serial-contains 'notepad: win_close'
vgate_assert 02 serial-contains 'gotabwm: host done'
vgate_assert 02 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 02 serial-contains 'dui: windows=4 focused='
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
