# live-tabwm-alttab.spec -- M42 UX hardening round 2 (2026-09-05, claim #1011, ADR 0018 addendum)
# class-B gate: TABWM's Alt-Tab parity (WMS6 Gate A semantics over the tab list).
#
# TWO headless boots with --screen (GPU armed) + --via-virtio (the HID chord
# transport). TABWM starts, then TWO apps exec into two tabs (GOTOP id=2,
# NOTE.ELF id=3 - the last mirror activates, so NOTE.ELF owns the tab).
# After `note: ready` the runner injects the REAL Alt+Tab chord
# (`--input-chords "alt-tab"` = LAlt modifier + Tab usage 0x2B, the WMS6
# Gate A vocabulary): the kernel fans the raw chord to the WM's kind-21
# stream; TABWM's handler proposes the next tab via the SAME alt_tab_next
# policy Ctrl+Tab uses (active row 1 -> row 0 = TOP) and commits through
# the kernel's ALT_TAB seam (focus + raise; focus auto-show re-reveals the
# hidden target). Evidence: the additive marker `tabwm: alt-tab id=2` and
# the kernel's own counter (`wm: alt_tab=`, printed by script3's `wm`).
#
# `top: resize relayout` is deliberately NOT asserted: both execs race
# ahead of the declarations on this choreography, so TOP's tab-aware
# full-viewport proposal is DEFERRED (inactive declaration), and the
# Alt-Tab path deliberately skips activate_tab (the commit is the
# kernel-side truth; the target keeps its applied viewport). The
# kernel-side proof that the commit LANDED is script3's `dui` row
# (`dui: windows=6 focused=2` - TOP, id 2, holds kernel focus after the
# chord) plus the kernel's own alt_tab= counter. NOTE: the retired Zig
# notepad printed a HARDCODED open marker; its Go successor NOTE.ELF (M66c
# #1485) prints the real id, but the authoritative tab-order evidence here is
# the kernel's `open: id=3` registration and TABWM's mirror-synced
# `tabwm: tab-switch idx=1 id=3`.
#
# Boot 02 (M63r #1424): the same pairing with `--input-chords "ctrl-tab"`.
# hidChord now maps that token (Ctrl + Tab usage 0x2B); a missing map
# used to abort CHORD-SEQ. Guest Ctrl+Tab uses activate_tab (not the
# ALT_TAB marker); this boot only proves the runner typed the chord.
# Ctrl+Tab policy parity with Alt+Tab is still class-A (alt_tab_next).

vgate_name live-tabwm-alttab "M42 UX r2: TABWM Alt-Tab parity (WMS6 Gate A chord -> alt_tab_next -> kernel ALT_TAB commit)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm start
exec GOTOP.ELF
exec NOTE.ELF
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

vgate_file script3.txt <<'EOF'
dui
wm
echo alttab-ok
EOF

vgate_file script3-ctrl.txt <<'EOF'
dui
wm
echo ctrl-tab-ok
EOF

# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotop.sh   ->  .build/go/GOTOP.ELF
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTOP.ELF")
if not os.path.exists(src):
    sys.exit("GOTOP.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotop.sh")
shutil.copy(src, os.path.join(share, "GOTOP.ELF"))
print("staged GOTOP.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOTOP.ELF")))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script.txt' \
    --input-chords "alt-tab" --input-chords-after "note: ready" --input-chords-delay 2 \
    --script3 '$RUN_DIR/script3.txt' --script3-after "tabwm: alt-tab id=2" --script3-delay 10 \
    --script-expect "alttab-ok" --timeout 260

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
# Two tabs: TOP first (id=2, tab-aware full viewport), NOTE.ELF second
# (id=3) - the last mirror activates.
vgate_assert 01 serial-contains 'top: tab-aware (full-viewport)'
# The kernel registered the second user window as id=3 and TABWM's
# mirror synced it into tab row 1.
vgate_assert 01 serial-contains 'open: id=3 owner=3'
vgate_assert 01 serial-contains 'tabwm: tab-switch idx=1 id=3'
vgate_assert 01 serial-contains 'note: ready'
# The chord: TABWM proposed TOP (the tab before the active NOTE.ELF row)
# and the kernel applied the commit.
vgate_assert 01 serial-contains 'tabwm: alt-tab id=2'
# The kernel ALT_TAB counter moved (the monitor prints ` alt_tab=` inside
# the wm: counter line - not `wm: alt_tab=`).
vgate_assert 01 serial-contains ' alt_tab='
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'alt_tab=[1-9][0-9]*', ser), "alt_tab counter check failed"
assert re.search(r'key_fan=[1-9][0-9]*', ser), "key_fan check failed (chord not fanned)"
# Kernel-side commit proof: TOP (id 2) holds kernel focus after the chord.
assert re.search(r'dui: windows=6 focused=2', ser), "focused-window check failed"
PY

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script.txt' \
    --input-chords "ctrl-tab" --input-chords-after "note: ready" --input-chords-delay 2 \
    --script3 '$RUN_DIR/script3-ctrl.txt' --script3-after "note: ready" --script3-delay 10 \
    --script-expect "ctrl-tab-ok" --timeout 260

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'tabwm: registered'
vgate_assert 02 serial-contains 'note: ready'
vgate_assert 02 output-contains 'CHORD-SEQ: typed "ctrl-tab"'
vgate_assert 02 serial-absent '[EXC] parking:'
