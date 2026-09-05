# live-tabwm-alttab.spec -- M42 UX hardening round 2 (2026-09-05, claim #1011, ADR 0018 addendum)
# class-B gate: TABWM's Alt-Tab parity (WMS6 Gate A semantics over the tab list).
#
# ONE headless boot with --screen (GPU armed) + --via-virtio (the HID chord
# transport). TABWM starts, then TWO apps exec into two tabs (CALC id=2,
# NOTEPAD id=3 - the last mirror activates, so NOTEPAD owns the tab).
# After `notepad: ready` the runner injects the REAL Alt+Tab chord
# (`--input-chords "alt-tab"` = LAlt modifier + Tab usage 0x2B, the WMS6
# Gate A vocabulary): the kernel fans the raw chord to the WM's kind-21
# stream; TABWM's handler proposes the next tab via the SAME alt_tab_next
# policy Ctrl+Tab uses (active row 1 -> row 0 = CALC) and commits through
# the kernel's ALT_TAB seam (focus + raise; focus auto-show re-reveals the
# hidden target). Evidence: the additive marker `tabwm: alt-tab id=2` and
# the kernel's own counter (`wm: alt_tab=`, printed by script3's `wm`).
#
# `calc: resize relayout` is deliberately NOT asserted: both execs race
# ahead of the declarations on this choreography, so CALC's tab-aware
# full-viewport proposal is DEFERRED (inactive declaration), and the
# Alt-Tab path deliberately skips activate_tab (the commit is the
# kernel-side truth; the target keeps its applied viewport). The
# kernel-side proof that the commit LANDED is script3's `dui` row
# (`dui: windows=6 focused=2` - CALC, id 2, holds kernel focus after the
# chord) plus the kernel's own alt_tab= counter. NOTE: NOTEPAD's own
# `notepad: open id=2` marker HARDCODES id=2 (user/src/notepad.zig), so
# the authoritative tab-order evidence here is the kernel's
# `open: id=3` registration and TABWM's mirror-synced
# `tabwm: tab-switch idx=1 id=3`.
#
# Single-chord leg only: the runner's chord vocabulary (hidChord in
# host/vm-runner/Sources/VMRunner/main.swift) maps `alt-tab` but has NO
# `ctrl-tab` / `alt-shift-tab` token (the ctrl-<x> pattern covers letters
# only), so a returning Ctrl+Tab leg would loud-fail the runner. The
# Ctrl+Tab policy parity is covered by the class-A suite (alt_tab_next is
# the SAME helper both chords route through).

vgate_name live-tabwm-alttab "M42 UX r2: TABWM Alt-Tab parity (WMS6 Gate A chord -> alt_tab_next -> kernel ALT_TAB commit)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm start
exec CALC.BIN
exec NOTEPAD.BIN
EOF

vgate_file script3.txt <<'EOF'
dui
wm
echo alttab-ok
EOF

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script.txt' \
    --input-chords "alt-tab" --input-chords-after "notepad: ready" --input-chords-delay 2 \
    --script3 '$RUN_DIR/script3.txt' --script3-after "tabwm: alt-tab id=2" --script3-delay 10 \
    --script-expect "alttab-ok" --timeout 260

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
# Two tabs: CALC first (id=2, tab-aware full viewport), NOTEPAD second
# (id=3) - the last mirror activates.
vgate_assert 01 serial-contains 'calc: open id=2'
vgate_assert 01 serial-contains 'calc: tab-aware (full-viewport)'
# The kernel registered the second user window as id=3 and TABWM's
# mirror synced it into tab row 1 (notepad's own open marker hardcodes
# id=2 - see the header note).
vgate_assert 01 serial-contains 'open: id=3 owner=3'
vgate_assert 01 serial-contains 'tabwm: tab-switch idx=1 id=3'
vgate_assert 01 serial-contains 'notepad: ready'
# The chord: TABWM proposed CALC (the tab before the active NOTEPAD row)
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
# Kernel-side commit proof: CALC (id 2) holds kernel focus after the chord.
assert re.search(r'dui: windows=6 focused=2', ser), "focused-window check failed"
PY
