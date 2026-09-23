# live-term-depth.spec -- M49 card SD5 class-B gate (issue #1132),
# retargeted by M73d (#1628) onto GOTERM.ELF (the Zig TERM.BIN retires
# into M60's leftovers; markers move `term:` -> `goterm:` by prefix alone,
# the M66c/NOTE pattern — no assertion dropped).
#
# GOTERM first-class window terminal: a share script prints 20 numbered
# lines into the kernel presentation grid, the host pointer (custom-virtio
# kind-2, guest pixels) drag-selects a row in the window's client area, and
# the Ctrl+Shift+C chord copies the selection into the shared clipboard —
# all kernel-side for ANY tty-bound window (kernel/src/input.zig chord
# table, driving_award.zig selection), which is what makes this a front-end
# swap. The monitor `clip` command then prints the copied bytes on the
# serial console — observed selection/copy. M73e (#1629) adds the reverse:
# the wide drag selects all 20 rows (259 B > the old 256 B input queue),
# Ctrl+Shift+V pastes it back through the bound tty (bracketed, DECSET
# 2004), and the editor runs every pasted line — tail line included. Reflow/
# scrollback math is class-A (kernel/src/terminal.zig tests) with the
# paint-path width sync. Boot default is unchanged (the serial console
# still belongs to the monitor while GOTERM owns only its window).
# M73d geometry: this gate boots WITHOUT GOTABWM.ELF (shim compositing,
# GOTERM's kind-8 declare refused — the plain .user window still paints)
# at the classic terminal rect 64,48,640,400 — the SAME rect TERM.BIN
# declared. M73l (#1661, cell 8x16) re-anchors this gate: the 384 px
# client fits 24 rows at cell_h=16 (was 48 at 8), so a 30-line script
# would scroll LINE-00 out of the view and the drag could no longer
# reach it. BIG.SH is 20 lines — still every line, total 22 <= 24 so
# the view never scrolls and line1 stays visible. Both drag ends move:
# y76 = row1 at cell_h=8 but row0 (the prompt line) at 16, so the start
# becomes y84 (row1, client top y64) and the end y392 (row20) — line1
# col0 -> line20 col79 = exactly the 20 BIG.SH rows (259 B, still > the
# 256 B input queue the M73e assertion exists to prove) the copy
# asserts count, with the prompt line excluded and `clip: LINE-00`
# (not `clip: gosh> source ...`) back as the clipboard head.
#
# #1688: run 02 boots the SAME chain WITH the seat registered —
# GOTABWM.ELF is staged by a tag-01 assert (the go-dogfood WINDOWS.SAV
# precedent) so run 01's shim boot stays byte-identical — and the
# drag-select travels the new slot-65 cmd 15 content forward. Under a
# seat, kernel terminal selection is dormant by WMS5 (pointer_tick
# returns before every selection site); the forward is the only path
# that can print `dui: term sel begin/end` there, which is what makes
# the >256 B Ctrl+Shift+V paste reachable in a seated boot. This is the
# class-B proof for claim #1688, which unblocks M73z (#1638).
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF (the seat —
#     same reason as live-term: without it the boot falls back to shim
#     compositing and GOTERM's declare is refused)
#   bash tools/go/build-goterm.sh   ->  .build/go/GOTERM.ELF

vgate_name live-term-depth "#1132 SD5 + M73d #1628: GOTERM pointer selection + Ctrl+Shift+C copy through the kernel grid"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
exec GOTERM.ELF
EOF

vgate_file clip.txt <<'EOF'
tty
clip
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "share")
for name, how in (("GOTERM.ELF", "build-goterm.sh"),):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)" % (name, os.path.getsize(src)))
lines = ["echo LINE-%02d pppp" % i for i in range(20)]
with open(os.path.join(share, "BIG.SH"), "w") as f:
    f.write("\n".join(lines) + "\n")
PY

vgate_run 01 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --input-string 'source BIG.SH'$'\n' \
    --input-string-after 'goterm: attached' \
    --pointer-virtio "68,84;68,84,d;696,392;696,392,u" \
    --pointer-virtio-after 'goterm: line source BIG.SH' \
    --input-chords "ctrl-shift-c,ctrl-shift-v,return,e,c,h,o,space,a,f,t,e,r,return" \
    --input-chords-after 'dui: term sel end' \
    --script2 '$RUN_DIR/clip.txt' \
    --script2-after 'goterm: line echo after' \
    --script-expect 'clip: LINE-00' \
    --timeout 150

vgate_assert 01 serial-contains 'goterm: ready'
vgate_assert 01 serial-contains 'goterm: attached'
vgate_assert 01 serial-contains 'goterm: line source BIG.SH'
vgate_assert 01 serial-contains 'goterm: done status=0'
vgate_assert 01 serial-contains 'tty: copy 259 bytes'
vgate_assert 01 serial-contains 'clip: LINE-00'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_done = ser.find("goterm: done status=0")
i_copy = ser.find("tty: copy ")
i_clip = ser.find("clip: LINE-00")
assert i_done >= 0, "BIG.SH did not finish"
assert i_copy > i_done, f"copy marker not after the script (done={i_done} copy={i_copy})"
assert i_clip > i_copy, f"clip read not after the copy (copy={i_copy} clip={i_clip})"
print("selection/copy ordering OK: goterm done < tty copy < clip read")
PY

# M73f-2 (#1632): the monitor `tty` line prints the ADR 0020 D1 drop
# counters. Assert the SHAPE after real activity — not zero: honest values
# until M73f-1/the acceptance card, where M73z pins 0/0 after a repaint.
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"tty\[\d+\]: out_dropped=\d+ in_dropped=\d+", ser)
assert m, "tty drop-counter line missing from serial"
i_copy = ser.find("tty: copy ")
assert i_copy >= 0, "copy marker missing (precondition)"
i_tty = ser.find(m.group(0))
assert i_tty > i_copy, f"tty line not after activity (copy={i_copy} tty={i_tty})"
print(f"drop-counter line OK: {m.group(0)} (after copy activity)")
PY

# M73e (#1629): the reverse direction — Ctrl+Shift+V pastes the >256 B
# selection back through the bound tty. The marker's byte count must
# exceed the old 256 B queue (the raised in_capacity + DECSET 2004 wrap
# are what make that land), and every pasted line — including the tail
# LINE-19, which only survives if NOTHING was dropped — must reach the
# editor and run.
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"tty: paste (\d+) bytes", ser)
assert m, "paste marker missing from serial"
n = int(m.group(1))
assert n > 256, f"paste must exceed the old 256 B queue (got {n})"
i_copy = ser.find("tty: copy ")
i_paste = ser.find(m.group(0))
assert i_copy >= 0 and i_paste > i_copy, f"paste not after copy (copy={i_copy} paste={i_paste})"
for seg in ("goterm: line LINE-00 pppp", "goterm: line LINE-10 pppp", "goterm: line LINE-19 pppp"):
    assert seg in ser, f"{seg} missing — paste lost bytes"
print(f"paste OK: {n} bytes; LINE-00..LINE-19 all reached the editor")
PY

# #1688 staged proof: stage the seat binary BETWEEN boots — run 01 (above)
# must never see it, so its shim boot stays byte-identical.
vgate_assert 01 python <<'PY'
import os, shutil, sys
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
dst = os.path.join(os.environ["VG_SHARE"], "GOTABWM.ELF")
shutil.copy(src, dst)
print("staged %s into share (%d bytes)" % (dst, os.path.getsize(src)))

# #1688 (b): one restored placeholder tab = the seat's stable state.
# loadSession sets stripDone (the two-tab choreography is skipped) and
# the single-tab countdown only arms on a LIVE declare — GOTERM's
# declare makes n=2, so neither closer fires and the hosted window
# survives the whole chain. Without this, hostTicks=16 closes GOTERM
# mid-drag (observed run 02 r1: `gotabwm: host close id=3` after 3 ptr
# events). `.tabs` v2 pinned byte vector (tabsv2.go layout): header
# [v2, active+1=0, count=1, seq=1, prefs=0] + one 69-byte record
# "Placeholder" (title 32 NUL-pad, flags 0, group 12, bin 24).
rec = b"Placeholder".ljust(32, b"\x00") + bytes(1) + bytes(12) + bytes(24)
blob = bytes([2, 0, 1, 1, 0, 0]) + rec
assert len(blob) == 6 + 69, len(blob)
sess = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
with open(sess, "wb") as f:
    f.write(blob)
print("staged %s (%d bytes)" % (sess, len(blob)))
PY

# Run 02: the identical chain with the seat registered. The forward
# (gotabwm handleWmPointer -> WmctlContentPtr -> wm_content_pointer ->
# content_pointer_pass) is the only way the sel markers can print here.
# Run 02 geometry: under the seat, the declare is ACCEPTED and the
# seat's host-view proposal (SetWindowRect full viewport) lands the
# window at 0,0 1280x720 — NOT run 01's refused-declare 64,48 640x400.
# Client top_y = 0+16 = 16, col = px/8: row1 col0 (LINE-00) = (4,36),
# row20 col79 (LINE-19) = (632,348). Observed mismatch before the
# retarget: begin landed line4/col8 -> `tty: copy 219 bytes`, head
# `clip: pppp`.
vgate_run 02 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --input-string 'source BIG.SH'$'\n' \
    --input-string-after 'goterm: attached' \
    --pointer-virtio "4,36;4,36,d;632,348;632,348,u" \
    --pointer-virtio-after 'goterm: line source BIG.SH' \
    --input-chords "ctrl-shift-c,ctrl-shift-v,return,e,c,h,o,space,a,f,t,e,r,return" \
    --input-chords-after 'dui: term sel end' \
    --script2 '$RUN_DIR/clip.txt' \
    --script2-after 'goterm: line echo after' \
    --script-expect 'clip: LINE-00' \
    --timeout 180

vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'gotabwm: session load n=1'
vgate_assert 02 serial-contains 'goterm: ready'
vgate_assert 02 serial-contains 'goterm: attached'
vgate_assert 02 serial-contains 'goterm: line source BIG.SH'
vgate_assert 02 serial-contains 'goterm: done status=0'
vgate_assert 02 serial-contains 'dui: term sel begin'
vgate_assert 02 serial-contains 'dui: term sel end'
vgate_assert 02 serial-contains 'tty: copy 259 bytes'
vgate_assert 02 serial-contains 'clip: LINE-00'
vgate_assert 02 serial-absent '\[EXC\]'
vgate_assert 02 serial-absent '[EXC] parking:'

# The #1688 chain order: seat registered BEFORE the drag, the forward's
# begin/end markers INSIDE it, and the copy/paste/readback after — with
# the script's own done/copy/clip tail in run 01's exact order.
vgate_assert 02 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_reg = ser.find("gotabwm: registered")
i_src = ser.find("goterm: line source BIG.SH")
i_begin = ser.find("dui: term sel begin")
i_end = ser.find("dui: term sel end")
i_done = ser.find("goterm: done status=0")
i_copy = ser.find("tty: copy ")
i_clip = ser.find("clip: LINE-00")
for name, i in (("registered", i_reg), ("source line", i_src),
                ("sel begin", i_begin), ("sel end", i_end),
                ("done", i_done), ("copy", i_copy), ("clip", i_clip)):
    assert i >= 0, f"{name} marker missing from serial"
assert i_reg < i_src < i_begin < i_end, (
    f"forward chain out of order: reg={i_reg} src={i_src} begin={i_begin} end={i_end}")
assert i_done < i_copy < i_clip, (
    f"script/copy/readback out of order: done={i_done} copy={i_copy} clip={i_clip}")
print("seated forward chain OK: registered < source < sel begin < sel end < copy < clip")
PY
