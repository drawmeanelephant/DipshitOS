# go-dogfood.spec -- M69a (issue #1528) class-B gate: the daily-driver beat on
# the DEFAULT Go seat (no `wm` override anywhere in this spec).
#
# Two boots, one beat. Each boot stages a slice of the beat's apps on the same
# default seat, and each slice is phase-gated: the harness forwards the next
# `exec` only after the previous app's own marker says it was HOSTED, so the
# serial order is the beat order and not the scheduler's. The six markers are
# printed by guest programs -- the seat and the apps themselves -- so no staged
# line and no harness echo can produce one (D2).
#
#   boot 01   exec GOSH.ELF -> exec NOTE.ELF        seat, gosh, note, ok
#   boot 02   exec GOCALC.ELF -> exec WEB.ELF PAGE  seat, calc, page, ok
#
# WHY TWO BOOTS, not one (both limits observed in-tree, neither invented here):
#
#  1. The runner forwards at most THREE command phases per boot (`--script`,
#     `--script2`, `--script3`, each released by its own `-after` marker --
#     host/vm-runner/Sources/VMRunner/main.swift). Four phase-gated execs need
#     four phases. Putting two execs in one phase would leave their declare
#     order to the scheduler, and an ordered assert on a race is a flake, not
#     evidence.
#  2. The kernel's task budget holds THREE Go runtimes live at once -- the seat
#     plus two clients (M65d / #1442: 3 kernel + 3x4 Ms + 1 spare; see the
#     maxTicks note in user/go/gotabwm/seat.go). A third concurrent Go CLIENT is
#     the documented wall in go-sh.spec / #1449. So each boot stages two client
#     apps, which is also the shape go-wm-default (one app) and go-wm-tabs (two)
#     already prove.
#
# The beat is therefore a tour of the default seat: shell+editor together,
# then calculator+browser together. All four apps, one seat, same share.
#
#   dogfood: seat   the seat's own line, after registration AND the one-seat
#                   probe returned: the DEFAULT seat owns the desktop.
#   dogfood: gosh   GOSH, on the accepted-declare path only (hosted, not
#   dogfood: note   merely running). Same for NOTE, and for GOCALC's `calc`.
#   dogfood: page   WEB, once, on the first frame of a LAID-OUT page reaching
#                   the scanout -- the page rendered.
#   dogfood: ok     the seat's host-done line, printed only when this boot
#                   actually hosted a tab (the dogfoodHosted latch): the boot's
#                   slice ran to completion.
#
# The browser is attached with WM_RPC kind 5 (attach), not kind 8
# (declare_fullscreen), so the page keeps the 512x384 geometry the live-web
# gates pin. Attach is what makes the page VISIBLE here: the seat paints the
# blank desktop only while its strip is empty, and that compose-N fill sits
# ABOVE user windows -- an undeclared browser would be silently overpainted.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh        ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gosh.sh           ->  .build/go/GOSH.ELF
#   bash tools/go/build-note.sh           ->  .build/go/NOTE.ELF
#   bash tools/go/build-gocalc.sh         ->  .build/go/GOCALC.ELF
#   bash tools/go/build-web.sh browser WEB->  .build/go/WEB.ELF
#   (the page is the pinned fixture user/go/browser/testdata/gate-page.html,
#    staged as /host/DOGFOOD.HTML; no new fixture)
#
# M69b subscribes to the same six markers for its `--screenshot-after`; see
# docs/testing.md.
#
# exec-order: assert-proven -- every phase gate is anchored on guest output
# (the seat's or an app's own marker) and each run ends on a marker only its
# stage script prints (`rx-dogfood-01-ok` / `rx-dogfood-02-ok`).

vgate_name go-dogfood "issue #1528 M69a: the DEFAULT Go seat hosts the daily-driver beat (GOSH+NOTE, then GOCALC+WEB) with ordered guest-printed dogfood: markers"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# --- boot 01: the shell and the editor on the default seat -----------------
# Phase 1 is released by the seat's own `dogfood: seat`, so GOSH starts only
# once the default seat is live and exclusive.
vgate_file script-01a.txt <<'EOF'
set GOMAXPROCS=1
exec GOSH.ELF
EOF

# Phase 2 waits on GOSH's `dogfood: gosh`: the shell is HOSTED as a GOTABWM
# tab before the editor is launched at all.
vgate_file script-01b.txt <<'EOF'
exec NOTE.ELF
EOF

# Phase 3 waits on the seat's `dogfood: ok` (host-done), so the beat slice has
# finished before the run ends; the end marker itself is script-owned.
vgate_file script-01c.txt <<'EOF'
echo rx-dogfood-01-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, how in (("GOTABWM.ELF", "build-gotabwm.sh"),
                  ("GOSH.ELF", "build-gosh.sh"),
                  ("NOTE.ELF", "build-note.sh"),
                  ("GOCALC.ELF", "build-gocalc.sh"),
                  ("WEB.ELF", "build-web.sh browser WEB")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name))
shutil.copy(os.path.join("user", "go", "browser", "testdata", "gate-page.html"),
            os.path.join(share, "DOGFOOD.HTML"))
# The whole point of this spec is the COMPILED default seat: a persisted `wm`
# row would test the setting instead of the daily driver.
if os.path.exists(os.path.join(share, "SETTINGS.TXT")):
    sys.exit("SETTINGS.TXT already present in the share; the dogfood beat must "
             "boot with no persisted `wm`")
print("staged GOTABWM/GOSH/NOTE/GOCALC/WEB + DOGFOOD.HTML from the pinned "
      "gate-page.html fixture")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --script '$RUN_DIR/script-01a.txt' \
    --script-after 'dogfood: seat' \
    --script2 '$RUN_DIR/script-01b.txt' \
    --script2-after 'dogfood: gosh' \
    --script3 '$RUN_DIR/script-01c.txt' \
    --script3-after 'dogfood: ok' \
    --script-expect 'rx-dogfood-01-ok' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# The DEFAULT seat, chosen by the compiled default and nothing else.
vgate_assert 01 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: seat-taken'
# dogfood: seat -- the seat's own announcement, after both returned.
vgate_assert 01 serial-contains 'dogfood: seat'

# --- GOSH, HOSTED as a GOTABWM tab (not Zig TABWM) --------------------------
vgate_assert 01 serial-contains 'exec: loaded GOSH.ELF'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gotabwm: rpc declare id='
vgate_assert 01 serial-contains 'gosh: declare accepted'
vgate_assert 01 serial-contains 'dogfood: gosh'
vgate_assert 01 serial-contains 'gotabwm: tab open id='
vgate_assert 01 serial-contains 'gotabwm: host focus id='
vgate_assert 01 serial-contains 'gotabwm: host view id='

# --- NOTE, the same seat, the same strip -----------------------------------
vgate_assert 01 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 01 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'dogfood: note'

# --- the slice's own close, then the run's end marker ----------------------
vgate_assert 01 serial-contains 'gotabwm: host done'
vgate_assert 01 serial-contains 'dogfood: ok'
vgate_assert 01 serial-contains 'rx-dogfood-01-ok'
# The Zig fallback seat never ran here: this is the Go seat, by absence too.
# NOT `serial-absent 'tabwm: registered'`: that is a SUBSTRING match (grep -F)
# and `gotabwm: registered` contains it, so the assert could never pass. The
# autostart line is unique to the fallback, and the line-start check in the
# python block below covers the Zig seat's own marker.
vgate_assert 01 serial-absent 'wm: autostart tabwm'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The order, at LINE START (a staged line that merely contains a marker cannot
# satisfy it -- the same reason go-sh.spec anchors its typed markers). The
# second half of the beat must be ABSENT from this boot: without that, a run
# that printed every marker off one app could pass as an ordered beat.
vgate_assert 01 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()


def at(marker):
    m = re.search(r"(?m)^" + re.escape(marker), ser)
    return -1 if m is None else m.start()


want = ["dogfood: seat", "dogfood: gosh", "dogfood: note", "dogfood: ok"]
pos = [(w, at(w)) for w in want]
missing = [w for w, i in pos if i < 0]
if missing:
    sys.exit("marker(s) never printed at line start: " + ", ".join(missing))
order = [w for w, _ in sorted(pos, key=lambda p: p[1])]
if order != want:
    sys.exit("beat order = " + " < ".join(order) + " want " + " < ".join(want))
for other in ("dogfood: calc", "dogfood: page"):
    if at(other) >= 0:
        sys.exit(other + " appeared in the shell/editor boot")
# The Zig seat's own marker, at line start: `serial-absent 'tabwm: registered'`
# is unusable here because `gotabwm: registered` contains it.
if re.search(r"(?m)^tabwm: registered", ser):
    sys.exit("the Zig TABWM seat registered: this is not the default Go seat")
print("boot 01 order ok: " + " < ".join(want) +
      " (and the calculator/browser half is absent)")
PY

# --- boot 02: the calculator and the browser on the same default seat -------
# Same share, same compiled default: boot 01 persisted no `wm` row.
vgate_file script-02a.txt <<'EOF'
set GOMAXPROCS=1
exec GOCALC.ELF
EOF

vgate_file script-02b.txt <<'EOF'
exec WEB.ELF /host/DOGFOOD.HTML
EOF

vgate_file script-02c.txt <<'EOF'
echo rx-dogfood-02-ok
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-02a.txt' \
    --script-after 'dogfood: seat' \
    --script2 '$RUN_DIR/script-02b.txt' \
    --script2-after 'dogfood: calc' \
    --script3 '$RUN_DIR/script-02c.txt' \
    --script3-after 'dogfood: ok' \
    --script-expect 'rx-dogfood-02-ok' --timeout 300

vgate_assert 02 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'dogfood: seat'

# --- GOCALC, hosted ---------------------------------------------------------
vgate_assert 02 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 02 serial-contains 'gotabwm: rpc declare id='
vgate_assert 02 serial-contains 'gocalc: declare accepted'
vgate_assert 02 serial-contains 'dogfood: calc'

# --- WEB shows a page, on the seat's own strip ------------------------------
vgate_assert 02 serial-contains 'exec: loaded WEB.ELF'
vgate_assert 02 serial-contains 'web: url /host/DOGFOOD.HTML'
vgate_assert 02 serial-contains 'web: parse nodes='
vgate_assert 02 serial-contains 'web: layout blocks='
vgate_assert 02 serial-contains 'web: paint items='
vgate_assert 02 serial-contains 'dogfood: page'
vgate_assert 02 serial-contains 'web: ready'
# The attach (kind 5) the browser sends, acknowledged by the seat: the page is
# on the strip -- the only arrangement in which the seat stops blanking over it.
vgate_assert 02 serial-contains 'gotabwm: rpc attach id='
vgate_assert 02 serial-contains 'gotabwm: tab open id='

vgate_assert 02 serial-contains 'gotabwm: host done'
vgate_assert 02 serial-contains 'dogfood: ok'
vgate_assert 02 serial-contains 'rx-dogfood-02-ok'
# See boot 01: `tabwm: registered` is a substring of `gotabwm: registered`.
vgate_assert 02 serial-absent 'wm: autostart tabwm'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

vgate_assert 02 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()


def at(marker):
    m = re.search(r"(?m)^" + re.escape(marker), ser)
    return -1 if m is None else m.start()


want = ["dogfood: seat", "dogfood: calc", "dogfood: page", "dogfood: ok"]
pos = [(w, at(w)) for w in want]
missing = [w for w, i in pos if i < 0]
if missing:
    sys.exit("marker(s) never printed at line start: " + ", ".join(missing))
order = [w for w, _ in sorted(pos, key=lambda p: p[1])]
if order != want:
    sys.exit("beat order = " + " < ".join(order) + " want " + " < ".join(want))
for other in ("dogfood: gosh", "dogfood: note"):
    if at(other) >= 0:
        sys.exit(other + " appeared in the calculator/browser boot")
if re.search(r"(?m)^tabwm: registered", ser):
    sys.exit("the Zig TABWM seat registered: this is not the default Go seat")
print("boot 02 order ok: " + " < ".join(want) +
      " (and the shell/editor half is absent)")
PY
