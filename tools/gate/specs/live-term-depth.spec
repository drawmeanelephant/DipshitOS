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
