# go-wm-seat.spec -- M57a (issue #1313) class-B gate: a Go WM registers the
# kernel render-server seat (slot 65) and composites a blank desktop.
#
# user/go/gotabwm is the Go second seat: REGISTER (slot 65 cmd 1), a
# blank-desktop composite into the seam-B scanout grant (tagged sys_mmap), and
# a REQUEST_PRESENT loop paced by the kind-18 COMPOSITE_TICK. One headless boot
# arms the GPU, execs GOTABWM.ELF, queries the seat while it is held, and lets
# the program exit cleanly (the kernel unregisters and falls back to the shim).
# Serial markers are the proof; each is printed only after its syscall returned.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gotabwm-ok`, which only the
# script prints, and both stage gates wait on guest output the program and the
# kernel produce (`gotabwm: present`, `wm: unregistered, shim resumed`), so a
# program that never ran cannot pass.

vgate_name go-wm-seat "issue #1313 M57a: a Go WM registers the slot-65 seat and composites a blank desktop on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Phase 1: the boot default reports shim (the seat is opt-in), then opt in by
# hand. `exec` returns immediately, so the rest of the run is stage-gated on
# the program's own output.
vgate_file script.txt <<'EOF'
wm
exec GOTABWM.ELF
EOF

# Phase 2: while the seat is held (after the program's first present), the `wm`
# report must name it.
vgate_file script2.txt <<'EOF'
wm
EOF

# Phase 3: after the program exits and the kernel unregisters the seat, the
# report is back to the shim; the run ends on the harness echo.
vgate_file script3.txt <<'EOF'
wm
echo rx-gotabwm-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
print("staged GOTABWM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTABWM.ELF")))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: present' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-ok' --timeout 180

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
# The seat is opt-in: the boot default reports shim, and so does the run's
# closing `wm` query.
vgate_assert 01 serial-count 'wm: none (shim compositing)' 2
# The program's own marker chain (each printed after its syscall succeeded).
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: seat-taken'
vgate_assert 01 serial-contains 'gotabwm: scanout'
vgate_assert 01 serial-contains 'gotabwm: draw'
vgate_assert 01 serial-contains 'gotabwm: holding seat'
vgate_assert 01 serial-contains 'gotabwm: tick'
vgate_assert 01 serial-contains 'gotabwm: present'
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
# The kernel's own report naming the live seat...
vgate_assert 01 serial-contains 'wm: registered pid='
vgate_assert 01 serial-contains 'wm: present_seq='
# ...and the clean teardown (the default falls back to the shim).
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
