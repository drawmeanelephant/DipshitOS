# live-wm1.spec -- Lane 1 WM1 (#707, claim 919) class-B gate: eight concurrent user windows
#
# M66c (#1485): the Zig notepad is retired, so the text-window client here is
# NOTE.ELF (Go). The lifecycle vocabulary is shared by design (`note:` mirrors
# `notepad:`), so the assertions below moved by prefix alone.
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
exec VIEW.BIN
exec NOTE.ELF
exec TOP.BIN
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
exec DEVCONS.BIN
exec SYSMON.BIN
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

# M66c (#1485): script2 waits on the Go client's own READY marker, not just on
# DESKTOP's. NOTE.ELF is the third of eight execs and its Go runtime start is the
# long pole in this burst — observed: with the old `desktop: ready` gate the
# sweep ran before NOTE.ELF had printed a single `note:` line. Waiting on the
# marker under test is also the correct choreography: the app decides when the
# boot may proceed, and its own `note: ready` assert below stays honest.
vgate_run 01 -- --display --input --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "note: ready" --script3 '$RUN_DIR/script3.txt' --script3-after "ps: ready" --script-expect "done-wm1-sweep" --timeout 150

vgate_assert 01 serial-contains 'winloop: open id=2'
vgate_assert 01 serial-contains 'view: ready'
vgate_assert 01 serial-contains 'note: ready'
vgate_assert 01 serial-contains 'top: ready'
vgate_assert 01 serial-contains 'desktop: ready'
vgate_assert 01 serial-contains 'devcons: ready'
vgate_assert 01 serial-contains 'sysmon: ready'
vgate_assert 01 serial-contains 'ps: ready'
vgate_assert 01 serial-contains '12 sys_win_open calls=8'
vgate_assert 01 serial-contains 'dui: windows=12 '
vgate_assert 01 serial-count ' user rect=' 8
vgate_assert 01 serial-contains 'done-wm1-sweep'
vgate_assert 01 serial-absent '[EXC] parking:'
