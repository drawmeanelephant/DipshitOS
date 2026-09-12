# go-goroutines.spec -- ADR 0027 D6 (issue #1214 round 2): the phase-0b
# threads proof for GOOS=virelai.
#
# The fixture (tools/go/goroutines.go) runs N=8 goroutines (N >
# GOMAXPROCS=2): each bumps an atomic counter and sends on a buffered
# channel; main drains 8 completions and prints the done line with
# counter == n. This exercises the whole ADR 0027 chain on real VZ:
#   1. slot 73 sys_thread op 0 — newosproc maps Ms onto same-process
#      kernel tasks (mp.g0.stack.hi / trampoline / mp), sysmon + GC Ms
#      included;
#   2. slot 74 sys_futex — lock_sema's semasleep/semawakeup park in the
#      kernel instead of spinning (the scheduler never deadlocks on a
#      parked M);
#   3. numCPUStartup = 2 — the runtime actually runs two Ps;
#   4. the cross-core scheduling proof: a slot-73 task carries the
#      PROCESS name, so the monitor `smp` report shows task=GOROUT.ELF
#      on a secondary core during the held window (the live-smp1/
#      live-smp-stress pattern).
#
# HOST PREREQUISITE (not hermetic — see tools/go/README.md):
# `just go-toolchain` must have produced .build/go/GOROUT.ELF.
#
# exec-order: assert-proven -- the run's --script-expect IS the program's
# own output line, so a green run always proves the exec'd program ran;
# the `syscalls` dump afterwards names the slot-73/74 call counts
# (asserted >= 2 for sys_thread by the python block below).

vgate_name go-goroutines "ADR 0027 D6: goroutines on kernel slot-73 tasks with the cross-core proof"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOROUT.ELF
EOF

vgate_file script2.txt <<'EOF'
syscalls
smp
echo gorout-held-window
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
for name in ("GOROUT.ELF", "GOARGS.ELF", "GOHELLO.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - "
                 "build the fork binaries first: just go-toolchain "
                 "(fork prerequisites in tools/go/README.md)")
    shutil.copy(src, os.path.join(share, name))
print("staged GOROUT.ELF (+ GOARGS/GOHELLO) into share")
PY

# script1 (exec only) sends at the default boot marker; script2 — the
# `syscalls` + `smp` dumps — fires on the program's own done line, so the
# counters reflect the completed run, and the held window keeps the VM
# alive through the cross-core smp report.
vgate_run 01 -- --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'go-goroutines done n=8 counter=8' --script-expect 'gorout-held-window' --timeout 120

vgate_assert 01 serial-contains 'exec: loaded GOROUT.ELF'
vgate_assert 01 serial-contains 'go-goroutines procs=2'
vgate_assert 01 serial-contains 'go-goroutines done n=8 counter=8'
vgate_assert 01 serial-contains 'task=GOROUT.ELF'
vgate_assert 01 serial-contains 'smp: secondary runs='
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# ADR 0027 D6: the strace signature of slot 73 — the `syscalls` report must
# name sys_thread with >= 2 create calls (sysmon + GC/steal Ms; the main M
# is the boot task and never calls it) and sys_futex present (lock_sema
# parked at least once across 8 goroutines + STW).
vgate_assert 01 python <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def calls(slot):
    for l in lines:
        m = re.search(r"%d (sys_\w+) calls=(\d+)" % slot, l)
        if m:
            return int(m.group(2))
    return None
n_thread = calls(73)
if n_thread is None:
    sys.exit("FAIL: no sys_thread row in the syscalls report")
if n_thread < 2:
    sys.exit("FAIL: ADR 0027 D6 needs sys_thread calls >= 2, got %d" % n_thread)
n_futex = calls(74)
if n_futex is None or n_futex < 1:
    sys.exit("FAIL: sys_futex unused (lock_sema never parked)")
# The cross-core proof: a slot-73 task carries the PROCESS name, so the smp
# report names it during the held window.
if not any("task=GOROUT.ELF" in l and "smp:" in l for l in lines):
    sys.exit("FAIL: no smp report line naming task=GOROUT.ELF (cross-core proof)")
print("go-goroutines python asserts OK: sys_thread=%d sys_futex=%d" % (n_thread, n_futex))
PY
