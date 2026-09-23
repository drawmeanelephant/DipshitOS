# live-wm1.spec -- Lane 1 WM1 (#707, claim 919) class-B gate: eight concurrent user windows
#
# M66c (#1485): the Zig notepad is retired, so the text-window client here is
# NOTE.ELF (Go). The lifecycle vocabulary is shared by design (`note:` mirrors
# `notepad:`), so the assertions below moved by prefix alone.
#
# M73d (#1628): the Zig terminal retires (TERM.BIN -> GOTERM.ELF), and the
# third window keeps its ZIG slot: this burst is at the 16-slot task-pool
# wall (M71f/M71h measurements below), and a third Go runtime beside
# NOTE.ELF + GOTOP.ELF dies before the eighth window opens. CHAT.BIN takes
# the slot — one `win_open`, resident, `chat: ready` — and it is the
# everyday Zig app that had no other class-B gate, so wm1 asserts it now.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-note.sh   ->  .build/go/NOTE.ELF

vgate_name live-wm1 "Lane 1 WM1: eight concurrent pool-backed user windows on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# M71f (#1565): GOMAXPROCS=1 for the whole burst. The eight-window burst is at
# the task-pool wall (scheduler.max_tasks = 16, M65d/#1442): at the compiled
# default GOMAXPROCS=2 a Go runtime is 4 Ms, so seven Zig windows + NOTE.ELF's 4
# + the kernel's 3 already sit at 14. Pinning 1 (3 Ms/runtime -- the repo's own
# "WM specs still pin GOMAXPROCS=1", kernel/src/scheduler.zig) keeps the burst
# cheap enough to have headroom for a Go runtime's transient syscall-spawned M.
vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
exec WINLOOP.BIN
exec CHAT.BIN
exec NOTE.ELF
exec GOTOP.ELF
exec DESKTOP.BIN
EOF

# M60 / #1374: Zig FILE.BIN deleted; a leftover Zig app fills the eighth window.
#
# M71f (#1565): SETTINGS.BIN is deleted, and the eighth window is NOT its Go
# successor. This spec's burst already carries NOTE.ELF (a Go runtime); a second
# one does NOT fit the 16-slot task pool and the guest runtime dies before it
# opens a window -- measured, not guessed:
#   * with GOSET.ELF as the eighth window, the Go runtime throws
#     `runtime.newosproc: sys_thread create failed` (task pool refused the
#     extra M) at the compiled GOMAXPROCS, and at GOMAXPROCS=1 it spins
#     without one syscall (7 windows, no `goset:` marker, `sys_thread`=4).
#   * GOSET.ELF alone, and GOSET.ELF beside NOTE.ELF on a lighter boot, both
#     pass (measured with throwaway single-run specs; the reports are
#     artifacts/m71f-goset-isolate-report.txt and
#     artifacts/m71f-twogo-report.txt, and both instruments were deleted
#     before this landed -- no orphan spec ships).
# So the panel is re-homed to the boot that needs it -- go-wm-default boot 01,
# the DEFAULT seat, where the panel writes `wm=tabwm` and the bytes are pinned.
# DEVCONS.BIN (Zig) takes the eighth slot, keeping this spec's actual claim (a
# WM holding EIGHT concurrent pool-backed user windows) intact.
vgate_file script2.txt <<'EOF'
# M71f (#1565) took this slot from SETTINGS.BIN to DEVCONS.BIN; M71g (#1566)
takes the NEXT one from SYSMON.BIN to RESMON.BIN. The two cards collide here:
both had to name a Zig substitute for a retired app, and two Go runtimes do
not fit the 16-slot task pool beside NOTE.ELF (see the note above). RESMON.BIN
is the Zig resident that reports the same resource story SYSMON.BIN did, and
it opens exactly ONE window -- measured, and the reason M21DEMO.BIN was not
used: it opens two (m21demo: open-a id=2 / open-b id=3), which would make
this a nine-window burst and quietly break the claim below.
exec DEVCONS.BIN
exec RESMON.BIN
exec PS.BIN
EOF

vgate_file script3.txt <<'EOF'
dui
syscalls
echo done-wm1-sweep
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

# M71h (#1567): the third window is NOT GOVIEW.ELF, and the reason is measured,
# not stylistic. Zig VIEW.BIN sat here, so the obvious retarget was the Go
# successor -- and on the board this spec carried before M71g (#1566) it PASSES
# (two Go runtimes, eight windows). On the MERGED board it does not, because
# M71g put GOTOP.ELF into the same burst: three Go runtimes do not fit the
# 16-slot task pool, so the EIGHTH window never starts and the pool says so --
#   error: no free scheduler pool slot
# measured with all seven earlier windows up: `ps: ready` never printed,
# `user rect=`=7, `12 sys_win_open calls=7`, pool refusals=1, zero exceptions
# (artifacts/m71h-probe3-report.txt; that throwaway instrument was deleted with
# the measurement, no orphan spec ships). The same burst with Zig TERM.BIN in
# this slot keeps the claim: 8 user rects, devcons/resmon/ps all ready, zero
# pool refusals, zero `sys_thread` failures (artifacts/m71h-probe2-report.txt,
# and this spec's own run). So the slot takes a Zig client -- the terminal, the
# most everyday app among the remaining Zig programs -- and the viewer's own
# coverage lives where it belongs: live-image-viewer (QOI decode + both error
# surfaces) and go-wm-seat run 04 (hosted as a full-viewport tab by the seat).
# M73d (#1628) retires that terminal: the slot stays ZIG (the pool math
# above is unchanged) and takes CHAT.BIN — one window, `chat: ready`,
# resident — asserted by this spec's run below, which becomes chat's own
# class-B proof (it had none).

# M66c (#1485): script2 waits on the Go client's own READY marker, not just on
# DESKTOP's. NOTE.ELF is the third of eight execs and its Go runtime start is the
# long pole in this burst — observed: with the old `desktop: ready` gate the
# sweep ran before NOTE.ELF had printed a single `note:` line. Waiting on the
# marker under test is also the correct choreography: the app decides when the
# boot may proceed, and its own `note: ready` assert below stays honest.
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

vgate_run 01 -- --display --input --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "note: ready" --script3 '$RUN_DIR/script3.txt' --script3-after "ps: ready" --script-expect "done-wm1-sweep" --timeout 150

vgate_assert 01 serial-contains 'winloop: open id=2'
# M71h (#1567): VIEW.BIN's own `view: ready` assert is gone with the binary.
# Its window's slot is the Zig terminal now (see the pool measurement above),
# and the viewer is covered by live-image-viewer and go-wm-seat run 04.
vgate_assert 01 serial-contains 'note: ready'
# M73d (#1628): `term: ready` moved with the retired Zig terminal; CHAT.BIN
# holds the slot (see the pool note above) and this is its own ready proof.
vgate_assert 01 serial-contains 'chat: ready'
vgate_assert 01 serial-contains 'top: ready'
vgate_assert 01 serial-contains 'desktop: ready'
vgate_assert 01 serial-contains 'devcons: ready'
vgate_assert 01 serial-contains 'resmon: ready'
vgate_assert 01 serial-contains 'ps: ready'
vgate_assert 01 serial-contains '12 sys_win_open calls=8'
vgate_assert 01 serial-contains 'dui: windows=12 '
vgate_assert 01 serial-count ' user rect=' 8
vgate_assert 01 serial-contains 'done-wm1-sweep'
vgate_assert 01 serial-absent '[EXC] parking:'
