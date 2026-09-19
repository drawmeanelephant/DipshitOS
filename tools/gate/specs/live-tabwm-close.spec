# live-tabwm-close.spec -- M42 UX hardening (2026-09-05, claim #1008 / ADR 0018 D2)
# class-B gate: the TABWM tab-close seam end to end on real VZ hardware.
#
# M66c (#1445): the client is NOTE.ELF, the Go successor to NOTEPAD.BIN. The
# lifecycle vocabulary is SHARED BY DESIGN (`note:` mirrors `notepad:`), so every
# assertion below moved by prefix alone. The WINDOW ID is the exception -- it is
# whatever the Go app is granted, so the close seam is checked by parsing the id
# this boot's own `note: open id=` reports rather than naming a literal.
#
# NOTEPAD.BIN still exists, and five specs still assert behaviour only the Zig
# app has (find/goto, theme tokens, the clipboard self-demo, the unsaved-decline
# contract), so its retirement is its own card rather than something this
# retarget silently assumes.
#
# One headless boot with --screen (GPU armed) + --via-virtio (the cv INPUT
# transport for pointer injection). The choreography:
#
#   1. `tabwm start`            -> TABWM.BIN registers, renders the sidebar.
#   2. `exec NOTE.ELF`          -> note: open id=<n>, the tab-aware declaration,
#                                  the full-viewport relayout (note: ready).
#   3. POINTER INJECTION after "note: ready": one click at (158, 70) - the
#      active tab pill's close box 'x' (x 148..168, tab row 0 y 58..96) in
#      TABWM's sidebar. TABWM's handle_pointer routes it to close_tab(0).
#   4. close_tab issues the NEW slot-65 WIN_CLOSE seam (cmd 13); the kernel
#      applies its own user_close release: the owner gets the real WIN_CLOSE
#      event, the WM gets the released mirror.
#   5. NOTE.ELF observes WIN_CLOSE ("note: win_close"), exits cleanly
#      ("note: exiting 0"); script3 (after the exit marker) reads the kernel
#      registry: the user window is GONE (dui: windows=4 - the four fixed layers
#      only; pre-M42 it would read 5, the hidden user window still registered).
#
# The load-bearing assertion is `tabwm: win-close id=<n> closed=1` - closed=1
# proves the KERNEL (not a hide-only fallback) applied the close. Pre-M42 the
# marker was a hide-only `tabwm: win-close id=<n>` (no closed= field).
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-note.sh   ->  .build/go/NOTE.ELF

vgate_name live-tabwm-close "M42 UX: TABWM tab close seam end to end (WM decision -> kernel release -> app exit)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec NOTE.ELF
EOF

vgate_file script3.txt <<'EOF'
dui
procs
echo rx-close-ok
EOF

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

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' --script2-after 'tabwm: sidebar-rendered' \
    --pointer-virtio '158,70,c' --pointer-virtio-after 'note: ready' \
    --script3 '$RUN_DIR/script3.txt' --script3-after 'note: exiting 0' \
    --script-expect 'rx-close-ok' --timeout 180

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'note: open id='
vgate_assert 01 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'note: resize relayout'
vgate_assert 01 serial-contains 'note: ready'
vgate_assert 01 serial-contains 'tabwm: tab-switch'
# The app received the kernel's real WIN_CLOSE event and exited cleanly.
vgate_assert 01 serial-contains 'note: win_close'
vgate_assert 01 serial-contains 'note: exiting 0'
# The kernel registry released the window: only the FOUR fixed layers
# remain (terminal + wallpaper + taskbar + dock) and no user-kind row.
vgate_assert 01 serial-contains 'dui: windows=4 focused='
vgate_assert 01 serial-absent 'dui: windows=5'
vgate_assert 01 serial-absent ' user rect='
vgate_assert 01 serial-absent '[EXC] parking:'

# The new close seam, against the id THIS boot's app reported: the WM decision
# (closed=1) has to name the same window the app opened, and a literal id would
# stop testing that as soon as the Go app's window census changed.
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"(?m)^note: open id=(\d+)$", ser)
if not m:
    sys.exit("no `note: open id=` line, so the app never declared a window")
wid = m.group(1)
if not re.search(r"(?m)^tabwm: win-close id=%s closed=1$" % wid, ser):
    sys.exit("no `tabwm: win-close id=%s closed=1`: the WM did not route the "
             "click to this window, or the kernel did not apply the release" % wid)
print("close seam ok: id=%s closed=1" % wid)
PY
