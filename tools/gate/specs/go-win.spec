# go-win.spec -- M53 Card 1 (issue #1245): the raw ADR 0007 window, from Go.
#
# GOWIN.ELF (tools/go/gowin.go, linked by tools/go/build-go.sh) opens one
# window, gives it a shared-anonymous back-buffer over sys_mmap, fills a
# visible rect, presents it, waits for CloseRequested and exits clean. No
# LIBUI, no webrender, no browser, no HTTP, no new syscall, kernel untouched.
# Serial markers are the proof; each one is printed only after its syscall
# succeeded.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-go.sh tools/go/gowin.go   ->  .build/go/GOWIN.ELF
#
# exec-order: assert-proven -- the run ends on `gowin OK`, which only the
# PROGRAM prints, and the stage gate that forwards the close waits on the
# program's own `gowin: present`; a program that never ran cannot pass. The
# residual risk is the program's tail sitting inside the expect window (a
# flaky FAIL, never a false pass). See tools/gate/SPEC.md (exec ordering).

vgate_name go-win "issue #1245 M53 Card 1: a Go EL0 program owns a raw ADR 0007 window on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOWIN.ELF
EOF

# CloseRequested is WIN_CLOSE (kind 8), pushed to the window's owner by the
# release path itself (kernel/src/driving_award.zig `remove_user_at`, reached
# by the privileged `dui close <n>`). The first user window of a boot is id 2
# — the terminal and the clock are the fixed windows — and the run asserts the
# program's own `gowin: open id=` line, so a drift in that id shows up as a
# failed gate rather than a silent pass.
vgate_file script2.txt <<'EOF'
dui close 2
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOWIN.ELF")
if not os.path.exists(src):
    sys.exit("GOWIN.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-go.sh tools/go/gowin.go")
shutil.copy(src, os.path.join(share, "GOWIN.ELF"))
print("staged GOWIN.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOWIN.ELF")))
PY

# script.txt is forwarded as soon as the boot self-test settles (the default
# --script-after marker); script2.txt is HELD until the program's own
# `gowin: present` line arrives, which is what orders the close after the
# frame is on the scanout.
# The scanout must be armed before a window can be opened at all: the kernel's
# driving_award.user_open refuses (`EINVAL`) while the manager is unarmed, and
# a run without the display never reaches a window id (observed: a first cut
# of this spec without --screen failed `gowin: error open -1`). The frame at
# `gowin: present` is captured for review; the card's proof is the markers.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-01' \
    --snapshot-after "gowin: present" \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after "gowin: present" \
    --script-expect "gowin OK" --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOWIN.ELF'
vgate_assert 01 serial-contains 'gowin: open id='
vgate_assert 01 serial-contains 'gowin: fill'
vgate_assert 01 serial-contains 'gowin: present'
vgate_assert 01 serial-contains 'gowin: close'
vgate_assert 01 serial-contains 'gowin OK'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
